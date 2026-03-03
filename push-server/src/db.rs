use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Deserialize;
use uuid::Uuid;

use crate::error::{AppError, AppResult};
use crate::models::{
    CompletePairingRequest, CompletePairingResponse, CreateMuteRequest, CreateMuteResponse,
    DeviceRecord, EventSource, MuteScope, RegisterDeviceRequest, RegisterDeviceResponse,
    StartPairingRequest, StartPairingResponse, TokenRecord,
};
use crate::token::{generate_token, hash_token};

const SCOPE_PAIRING_COMPLETE: &str = "pairing_complete";
const SCOPE_DEVICE_REGISTER: &str = "device_register";
const SCOPE_HOST_INGEST: &str = "host_ingest";
const SCOPE_DEVICE_API: &str = "device_api";
const SCOPE_COMPAT_NOTIFY: &str = "compat_notify";

#[derive(Debug, Deserialize)]
struct LegacyDeviceToken {
    token: String,
    #[serde(default)]
    sandbox: bool,
    #[serde(default)]
    device_id: String,
    #[serde(default)]
    server_name: String,
}

pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn new(path: &Path) -> AppResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let mut conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;

        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS tokens (
                id TEXT PRIMARY KEY,
                token_hash TEXT NOT NULL UNIQUE,
                scope TEXT NOT NULL,
                subject_id TEXT NOT NULL,
                expires_at TEXT,
                consumed_at TEXT,
                revoked_at TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tokens_scope_subject ON tokens(scope, subject_id);

            CREATE TABLE IF NOT EXISTS pairings (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                server_name TEXT NOT NULL,
                pair_token_id TEXT NOT NULL UNIQUE,
                register_token_id TEXT NOT NULL UNIQUE,
                host_id TEXT,
                expires_at TEXT NOT NULL,
                completed_at TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS hosts (
                id TEXT PRIMARY KEY,
                pairing_id TEXT NOT NULL UNIQUE,
                host_name TEXT NOT NULL,
                platform TEXT NOT NULL,
                ingest_token_id TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                revoked_at TEXT
            );

            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                pairing_id TEXT,
                host_id TEXT,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                server_name TEXT NOT NULL,
                apns_token TEXT NOT NULL UNIQUE,
                sandbox INTEGER NOT NULL,
                device_api_token_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                revoked_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_devices_host_id ON devices(host_id);
            CREATE INDEX IF NOT EXISTS idx_devices_pairing_id ON devices(pairing_id);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_device_id_active
                ON devices(device_id)
                WHERE revoked_at IS NULL;

            CREATE TABLE IF NOT EXISTS mutes (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                session_name TEXT,
                pane_target TEXT,
                source TEXT NOT NULL,
                until_ts TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_mutes_device_id ON mutes(device_id);

            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            "#,
        )?;

        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn bootstrap_compat_token(&self, raw_token: &str) -> AppResult<()> {
        let now = now_utc();
        let token_hash = hash_token(raw_token);
        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        tx.execute(
            "DELETE FROM tokens WHERE scope = ?1",
            params![SCOPE_COMPAT_NOTIFY],
        )?;

        tx.execute(
            "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
             VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)",
            params![
                Uuid::new_v4().to_string(),
                token_hash,
                SCOPE_COMPAT_NOTIFY,
                "compat",
                now.to_rfc3339(),
            ],
        )?;

        tx.commit()?;
        Ok(())
    }

    pub fn import_legacy_device_tokens_once(&self, path: Option<&Path>) -> AppResult<u64> {
        if self.meta_value("legacy_import_done")?.as_deref() == Some("1") {
            return Ok(0);
        }

        let Some(path) = path else {
            self.set_meta_value("legacy_import_done", "1")?;
            return Ok(0);
        };

        if !path.exists() {
            self.set_meta_value("legacy_import_done", "1")?;
            return Ok(0);
        }

        let content = std::fs::read_to_string(path)?;
        let records: Vec<LegacyDeviceToken> = serde_json::from_str(&content)?;

        let now = now_utc();
        let mut imported = 0u64;
        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        for record in records {
            if record.token.trim().is_empty() {
                continue;
            }

            let device_id = if record.device_id.trim().is_empty() {
                let digest = hash_token(&record.token);
                format!("legacy-{}", &digest[..16])
            } else {
                record.device_id
            };
            let server_name = if record.server_name.trim().is_empty() {
                "Legacy".to_string()
            } else {
                record.server_name
            };
            let device_name = format!("Legacy {}", device_id);

            let existing = tx
                .query_row(
                    "SELECT id, device_api_token_id FROM devices
                     WHERE revoked_at IS NULL AND (device_id = ?1 OR apns_token = ?2)
                     LIMIT 1",
                    params![device_id, record.token],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                )
                .optional()?;

            if let Some((existing_id, device_api_token_id)) = existing {
                tx.execute(
                    "UPDATE devices SET
                        pairing_id = NULL,
                        host_id = NULL,
                        device_id = ?1,
                        device_name = ?2,
                        server_name = ?3,
                        apns_token = ?4,
                        sandbox = ?5,
                        device_api_token_id = ?6,
                        updated_at = ?7,
                        revoked_at = NULL
                     WHERE id = ?8",
                    params![
                        device_id,
                        device_name,
                        server_name,
                        record.token,
                        bool_to_int(record.sandbox),
                        device_api_token_id,
                        now.to_rfc3339(),
                        existing_id
                    ],
                )?;
                imported += 1;
            } else {
                let device_row_id = Uuid::new_v4().to_string();
                let token_id = Uuid::new_v4().to_string();
                let token_raw = generate_token();
                let token_hash = hash_token(&token_raw);

                tx.execute(
                    "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
                     VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)",
                    params![
                        token_id,
                        token_hash,
                        SCOPE_DEVICE_API,
                        device_row_id,
                        now.to_rfc3339(),
                    ],
                )?;

                tx.execute(
                    "INSERT INTO devices (
                        id, pairing_id, host_id, device_id, device_name, server_name,
                        apns_token, sandbox, device_api_token_id, created_at, updated_at, revoked_at
                    ) VALUES (?1, NULL, NULL, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, NULL)",
                    params![
                        device_row_id,
                        device_id,
                        device_name,
                        server_name,
                        record.token,
                        bool_to_int(record.sandbox),
                        token_id,
                        now.to_rfc3339(),
                    ],
                )?;
                imported += 1;
            }
        }

        tx.execute(
            "INSERT INTO meta(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params!["legacy_import_done", "1"],
        )?;

        tx.commit()?;
        Ok(imported)
    }

    pub fn start_pairing(
        &self,
        req: StartPairingRequest,
        pairing_ttl_seconds: i64,
    ) -> AppResult<StartPairingResponse> {
        if req.device_id.trim().is_empty() {
            return Err(AppError::bad_request("device_id is required"));
        }
        if req.device_name.trim().is_empty() {
            return Err(AppError::bad_request("device_name is required"));
        }
        if req.server_name.trim().is_empty() {
            return Err(AppError::bad_request("server_name is required"));
        }

        let now = now_utc();
        let expires_at = now + Duration::seconds(pairing_ttl_seconds.max(60));

        let pairing_id = Uuid::new_v4().to_string();
        let pair_token_id = Uuid::new_v4().to_string();
        let register_token_id = Uuid::new_v4().to_string();

        let pairing_token = generate_token();
        let device_register_token = generate_token();

        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        tx.execute(
            "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, ?6)",
            params![
                pair_token_id,
                hash_token(&pairing_token),
                SCOPE_PAIRING_COMPLETE,
                pairing_id,
                expires_at.to_rfc3339(),
                now.to_rfc3339(),
            ],
        )?;

        tx.execute(
            "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, ?6)",
            params![
                register_token_id,
                hash_token(&device_register_token),
                SCOPE_DEVICE_REGISTER,
                pairing_id,
                expires_at.to_rfc3339(),
                now.to_rfc3339(),
            ],
        )?;

        tx.execute(
            "INSERT INTO pairings (
                id, device_id, device_name, server_name,
                pair_token_id, register_token_id,
                host_id, expires_at, completed_at, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, NULL, ?8)",
            params![
                pairing_id,
                req.device_id,
                req.device_name,
                req.server_name,
                pair_token_id,
                register_token_id,
                expires_at.to_rfc3339(),
                now.to_rfc3339(),
            ],
        )?;

        tx.commit()?;

        Ok(StartPairingResponse {
            pairing_id,
            pairing_token,
            device_register_token,
            expires_at,
        })
    }

    pub fn complete_pairing(
        &self,
        req: CompletePairingRequest,
        ingest_url: &str,
    ) -> AppResult<CompletePairingResponse> {
        if req.pairing_token.trim().is_empty() {
            return Err(AppError::bad_request("pairing_token is required"));
        }
        if req.host_name.trim().is_empty() {
            return Err(AppError::bad_request("host_name is required"));
        }
        if req.platform.trim().is_empty() {
            return Err(AppError::bad_request("platform is required"));
        }

        let now = now_utc();
        let token_hash = hash_token(&req.pairing_token);
        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        let token_row = tx
            .query_row(
                "SELECT id, scope, subject_id, expires_at, consumed_at, revoked_at
                 FROM tokens WHERE token_hash = ?1",
                params![token_hash],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()?;

        let (token_id, scope, pairing_id, expires_at, consumed_at, revoked_at) = token_row
            .ok_or_else(|| AppError::unauthorized("pairing token is invalid"))?;

        if scope != SCOPE_PAIRING_COMPLETE {
            return Err(AppError::unauthorized("token scope mismatch"));
        }
        if revoked_at.is_some() {
            return Err(AppError::unauthorized("pairing token was revoked"));
        }
        if consumed_at.is_some() {
            return Err(AppError::conflict("pairing token already used"));
        }
        if let Some(exp) = expires_at {
            let ts = parse_ts(&exp)?;
            if now >= ts {
                return Err(AppError::unauthorized("pairing token has expired"));
            }
        }

        let completed_at = tx
            .query_row(
                "SELECT completed_at FROM pairings WHERE id = ?1",
                params![pairing_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;

        match completed_at {
            Some(Some(_)) => return Err(AppError::conflict("pairing already completed")),
            Some(None) => {}
            None => return Err(AppError::unauthorized("pairing not found")),
        }

        let host_id = Uuid::new_v4().to_string();
        let ingest_token_id = Uuid::new_v4().to_string();
        let ingest_token = generate_token();

        tx.execute(
            "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
             VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)",
            params![
                ingest_token_id,
                hash_token(&ingest_token),
                SCOPE_HOST_INGEST,
                host_id,
                now.to_rfc3339(),
            ],
        )?;

        tx.execute(
            "INSERT INTO hosts (id, pairing_id, host_name, platform, ingest_token_id, created_at, revoked_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)",
            params![
                host_id,
                pairing_id,
                req.host_name,
                req.platform,
                ingest_token_id,
                now.to_rfc3339(),
            ],
        )?;

        tx.execute(
            "UPDATE pairings SET host_id = ?1, completed_at = ?2 WHERE id = ?3",
            params![host_id, now.to_rfc3339(), pairing_id],
        )?;

        tx.execute(
            "UPDATE devices SET host_id = ?1, updated_at = ?2
             WHERE pairing_id = ?3 AND revoked_at IS NULL",
            params![host_id, now.to_rfc3339(), pairing_id],
        )?;

        tx.execute(
            "UPDATE tokens SET consumed_at = ?1 WHERE id = ?2",
            params![now.to_rfc3339(), token_id],
        )?;

        tx.commit()?;

        Ok(CompletePairingResponse {
            host_id,
            ingest_token,
            ingest_url: ingest_url.to_string(),
        })
    }

    pub fn register_device(
        &self,
        register_token: &str,
        req: RegisterDeviceRequest,
    ) -> AppResult<RegisterDeviceResponse> {
        if register_token.trim().is_empty() {
            return Err(AppError::unauthorized("missing bearer token"));
        }
        if req.token.trim().is_empty() {
            return Err(AppError::bad_request("token is required"));
        }
        if req.device_id.trim().is_empty() {
            return Err(AppError::bad_request("device_id is required"));
        }
        if req.server_name.trim().is_empty() {
            return Err(AppError::bad_request("server_name is required"));
        }

        let now = now_utc();
        let register_token_hash = hash_token(register_token);

        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        let token_row = tx
            .query_row(
                "SELECT id, scope, subject_id, expires_at, consumed_at, revoked_at
                 FROM tokens WHERE token_hash = ?1",
                params![register_token_hash],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()?;

        let (_token_id, scope, pairing_id, expires_at, _consumed_at, revoked_at) = token_row
            .ok_or_else(|| AppError::unauthorized("registration token is invalid"))?;

        if scope != SCOPE_DEVICE_REGISTER {
            return Err(AppError::unauthorized("token scope mismatch"));
        }
        if revoked_at.is_some() {
            return Err(AppError::unauthorized("registration token was revoked"));
        }
        if let Some(exp) = expires_at {
            let ts = parse_ts(&exp)?;
            if now >= ts {
                return Err(AppError::unauthorized("registration token has expired"));
            }
        }

        let pairing = tx
            .query_row(
                "SELECT device_name, host_id FROM pairings WHERE id = ?1",
                params![pairing_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()?;

        let (device_name, host_id) = pairing.ok_or_else(|| AppError::unauthorized("pairing not found"))?;

        let existing = tx
            .query_row(
                "SELECT id, device_api_token_id FROM devices
                 WHERE device_id = ?1 AND revoked_at IS NULL
                 LIMIT 1",
                params![req.device_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;

        if let Some((existing_id, old_device_api_token_id)) = existing {
            revoke_conflicting_apns_token(&tx, &req.token, Some(&existing_id), now)?;

            let new_device_api_token_id = Uuid::new_v4().to_string();
            let new_device_api_token_raw = generate_token();
            tx.execute(
                "UPDATE tokens SET revoked_at = ?1 WHERE id = ?2",
                params![now.to_rfc3339(), old_device_api_token_id],
            )?;
            tx.execute(
                "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
                 VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)",
                params![
                    new_device_api_token_id,
                    hash_token(&new_device_api_token_raw),
                    SCOPE_DEVICE_API,
                    existing_id,
                    now.to_rfc3339(),
                ],
            )?;
            tx.execute(
                "UPDATE devices SET
                    pairing_id = ?1,
                    host_id = ?2,
                    device_name = ?3,
                    server_name = ?4,
                    apns_token = ?5,
                    sandbox = ?6,
                    device_api_token_id = ?7,
                    updated_at = ?8,
                    revoked_at = NULL
                 WHERE id = ?9",
                params![
                    pairing_id,
                    host_id,
                    device_name,
                    req.server_name,
                    req.token,
                    bool_to_int(req.sandbox),
                    new_device_api_token_id,
                    now.to_rfc3339(),
                    existing_id,
                ],
            )?;

            tx.commit()?;

            return Ok(RegisterDeviceResponse {
                registration_id: existing_id,
                device_api_token: new_device_api_token_raw,
            });
        } else {
            let new_id = Uuid::new_v4().to_string();
            revoke_conflicting_apns_token(&tx, &req.token, None, now)?;

            let token_id = Uuid::new_v4().to_string();
            let token_raw = generate_token();
            tx.execute(
                "INSERT INTO tokens (id, token_hash, scope, subject_id, expires_at, consumed_at, revoked_at, created_at)
                 VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5)",
                params![
                    token_id,
                    hash_token(&token_raw),
                    SCOPE_DEVICE_API,
                    new_id,
                    now.to_rfc3339(),
                ],
            )?;

            tx.execute(
                "INSERT INTO devices (
                    id, pairing_id, host_id, device_id, device_name, server_name,
                    apns_token, sandbox, device_api_token_id, created_at, updated_at, revoked_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, NULL)",
                params![
                    new_id,
                    pairing_id,
                    host_id,
                    req.device_id,
                    device_name,
                    req.server_name,
                    req.token,
                    bool_to_int(req.sandbox),
                    token_id,
                    now.to_rfc3339(),
                ],
            )?;

            tx.commit()?;

            return Ok(RegisterDeviceResponse {
                registration_id: new_id,
                device_api_token: token_raw,
            });
        }
    }

    pub fn validate_token(&self, raw_token: &str, allowed_scopes: &[&str]) -> AppResult<TokenRecord> {
        if raw_token.trim().is_empty() {
            return Err(AppError::unauthorized("missing bearer token"));
        }

        let token_hash = hash_token(raw_token);
        let conn = lock_conn(&self.conn)?;

        let row = conn
            .query_row(
                "SELECT id, scope, subject_id, expires_at, consumed_at, revoked_at
                 FROM tokens WHERE token_hash = ?1",
                params![token_hash],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()?;

        let (id, scope, subject_id, expires_at, consumed_at, revoked_at) =
            row.ok_or_else(|| AppError::unauthorized("token is invalid"))?;

        if !allowed_scopes.iter().any(|s| *s == scope.as_str()) {
            return Err(AppError::unauthorized("token scope mismatch"));
        }
        if revoked_at.is_some() {
            return Err(AppError::unauthorized("token was revoked"));
        }
        if let Some(exp) = expires_at {
            let exp_ts = parse_ts(&exp)?;
            if Utc::now() >= exp_ts {
                return Err(AppError::unauthorized("token has expired"));
            }
        }

        let consumed_at = consumed_at.map(|ts| parse_ts(&ts)).transpose()?;

        Ok(TokenRecord {
            id,
            scope,
            subject_id,
            consumed_at,
        })
    }

    pub fn token_scope_host_ingest() -> &'static str {
        SCOPE_HOST_INGEST
    }

    pub fn token_scope_compat_notify() -> &'static str {
        SCOPE_COMPAT_NOTIFY
    }

    pub fn token_scope_device_api() -> &'static str {
        SCOPE_DEVICE_API
    }

    pub fn list_devices_for_host(&self, host_id: &str) -> AppResult<Vec<DeviceRecord>> {
        let conn = lock_conn(&self.conn)?;
        let mut stmt = conn.prepare(
            "SELECT id, device_id, server_name, apns_token, sandbox
             FROM devices
             WHERE revoked_at IS NULL AND host_id = ?1",
        )?;
        let mut rows = stmt.query(params![host_id])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            out.push(DeviceRecord {
                id: row.get(0)?,
                device_id: row.get(1)?,
                server_name: row.get(2)?,
                apns_token: row.get(3)?,
                sandbox: row.get::<_, i64>(4)? != 0,
            });
        }
        Ok(out)
    }

    pub fn list_all_devices(&self) -> AppResult<Vec<DeviceRecord>> {
        let conn = lock_conn(&self.conn)?;
        let mut stmt = conn.prepare(
            "SELECT id, device_id, server_name, apns_token, sandbox
             FROM devices
             WHERE revoked_at IS NULL",
        )?;
        let mut rows = stmt.query([])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            out.push(DeviceRecord {
                id: row.get(0)?,
                device_id: row.get(1)?,
                server_name: row.get(2)?,
                apns_token: row.get(3)?,
                sandbox: row.get::<_, i64>(4)? != 0,
            });
        }
        Ok(out)
    }

    pub fn create_mute(&self, subject_device_row_id: &str, req: CreateMuteRequest) -> AppResult<CreateMuteResponse> {
        validate_mute_request(&req)?;

        let conn = lock_conn(&self.conn)?;
        let device_id = conn
            .query_row(
                "SELECT device_id FROM devices WHERE id = ?1 AND revoked_at IS NULL",
                params![subject_device_row_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| AppError::unauthorized("device token subject is invalid"))?;

        let id = Uuid::new_v4().to_string();
        let now = now_utc();

        conn.execute(
            "INSERT INTO mutes (id, device_id, scope, session_name, pane_target, source, until_ts, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                id,
                device_id,
                req.scope.as_str(),
                req.session_name,
                req.pane_target,
                req.source.as_str(),
                req.until.map(|t| t.to_rfc3339()),
                now.to_rfc3339(),
            ],
        )?;

        Ok(CreateMuteResponse { id })
    }

    pub fn delete_mute(&self, subject_device_row_id: &str, mute_id: &str) -> AppResult<bool> {
        let conn = lock_conn(&self.conn)?;
        let device_id = conn
            .query_row(
                "SELECT device_id FROM devices WHERE id = ?1 AND revoked_at IS NULL",
                params![subject_device_row_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| AppError::unauthorized("device token subject is invalid"))?;

        let changed = conn.execute(
            "DELETE FROM mutes WHERE id = ?1 AND device_id = ?2",
            params![mute_id, device_id],
        )?;

        Ok(changed > 0)
    }

    pub fn is_muted(&self, device_id: &str, source: EventSource, pane_target: Option<&str>) -> AppResult<bool> {
        let conn = lock_conn(&self.conn)?;
        let mut stmt = conn.prepare(
            "SELECT scope, session_name, pane_target, source, until_ts
             FROM mutes
             WHERE device_id = ?1 AND (source = 'all' OR source = ?2)",
        )?;
        let mut rows = stmt.query(params![device_id, source.as_str()])?;

        let now = now_utc();
        let session_name = pane_target.and_then(extract_session_name);

        while let Some(row) = rows.next()? {
            let scope: String = row.get(0)?;
            let mute_session: Option<String> = row.get(1)?;
            let mute_pane: Option<String> = row.get(2)?;
            let until_ts: Option<String> = row.get(4)?;

            if let Some(until) = until_ts {
                let until_dt = parse_ts(&until)?;
                if now >= until_dt {
                    continue;
                }
            }

            let matched = match scope.as_str() {
                "host" => true,
                "session" => mute_session.as_deref() == session_name,
                "pane" => mute_pane.as_deref() == pane_target,
                _ => false,
            };

            if matched {
                return Ok(true);
            }
        }

        Ok(false)
    }

    pub fn revoke_devices(&self, device_ids: &[String]) -> AppResult<u64> {
        if device_ids.is_empty() {
            return Ok(0);
        }

        let now = now_utc();
        let mut conn = lock_conn(&self.conn)?;
        let tx = conn.transaction()?;

        let mut changed = 0u64;
        for device_id in device_ids {
            tx.execute(
                "UPDATE tokens
                 SET revoked_at = ?1
                 WHERE id IN (
                    SELECT device_api_token_id FROM devices WHERE id = ?2
                 )",
                params![now.to_rfc3339(), device_id],
            )?;

            let rows = tx.execute(
                "UPDATE devices SET revoked_at = ?1, updated_at = ?1 WHERE id = ?2",
                params![now.to_rfc3339(), device_id],
            )?;
            if rows > 0 {
                changed += rows as u64;
            }
        }

        tx.commit()?;
        Ok(changed)
    }

    fn meta_value(&self, key: &str) -> AppResult<Option<String>> {
        let conn = lock_conn(&self.conn)?;
        let value = conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![key],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        Ok(value)
    }

    fn set_meta_value(&self, key: &str, value: &str) -> AppResult<()> {
        let conn = lock_conn(&self.conn)?;
        conn.execute(
            "INSERT INTO meta(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

fn validate_mute_request(req: &CreateMuteRequest) -> AppResult<()> {
    match req.scope {
        MuteScope::Host => {}
        MuteScope::Session => {
            if req
                .session_name
                .as_ref()
                .map(|s| s.trim().is_empty())
                .unwrap_or(true)
            {
                return Err(AppError::bad_request("session_name is required for session scope"));
            }
        }
        MuteScope::Pane => {
            if req
                .pane_target
                .as_ref()
                .map(|s| s.trim().is_empty())
                .unwrap_or(true)
            {
                return Err(AppError::bad_request("pane_target is required for pane scope"));
            }
        }
    }

    if let Some(until) = req.until {
        if until <= Utc::now() {
            return Err(AppError::bad_request("until must be in the future"));
        }
    }

    Ok(())
}

fn revoke_conflicting_apns_token(
    tx: &Transaction<'_>,
    apns_token: &str,
    keep_id: Option<&str>,
    now: DateTime<Utc>,
) -> AppResult<()> {
    let conflict = tx
        .query_row(
            "SELECT id, device_api_token_id
             FROM devices
             WHERE apns_token = ?1 AND revoked_at IS NULL
             LIMIT 1",
            params![apns_token],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;

    if let Some((conflict_id, conflict_token_id)) = conflict {
        if keep_id
            .map(|id| id == conflict_id.as_str())
            .unwrap_or(false)
        {
            return Ok(());
        }

        tx.execute(
            "UPDATE tokens SET revoked_at = ?1 WHERE id = ?2",
            params![now.to_rfc3339(), conflict_token_id],
        )?;
        tx.execute(
            "UPDATE devices SET revoked_at = ?1, updated_at = ?1 WHERE id = ?2",
            params![now.to_rfc3339(), conflict_id],
        )?;
    }

    Ok(())
}

fn parse_ts(raw: &str) -> AppResult<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| AppError::internal(format!("invalid timestamp: {}", e)))
}

fn now_utc() -> DateTime<Utc> {
    Utc::now()
}

fn bool_to_int(v: bool) -> i64 {
    if v {
        1
    } else {
        0
    }
}

fn extract_session_name(pane_target: &str) -> Option<&str> {
    pane_target.split(':').next()
}

fn lock_conn(conn: &Mutex<Connection>) -> AppResult<std::sync::MutexGuard<'_, Connection>> {
    conn.lock()
        .map_err(|_| AppError::internal("database lock poisoned"))
}
