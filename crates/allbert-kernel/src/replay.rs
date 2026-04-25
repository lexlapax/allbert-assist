use allbert_proto::Span;
use serde::{Deserialize, Serialize};

pub const TRACE_RECORD_SCHEMA_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TraceRecord {
    pub schema_version: u16,
    pub record_type: TraceRecordType,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TraceRecordType {
    Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraceRecordError {
    UnsupportedSchemaVersion { found: u16, supported: u16 },
}

impl std::fmt::Display for TraceRecordError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedSchemaVersion { found, supported } => write!(
                f,
                "unsupported trace schema version {found}; this build supports version {supported}"
            ),
        }
    }
}

impl std::error::Error for TraceRecordError {}

impl TraceRecord {
    pub fn span(span: Span) -> Self {
        Self {
            schema_version: TRACE_RECORD_SCHEMA_VERSION,
            record_type: TraceRecordType::Span,
            span,
        }
    }

    pub fn validate_schema_version(&self) -> Result<(), TraceRecordError> {
        if self.schema_version == TRACE_RECORD_SCHEMA_VERSION {
            Ok(())
        } else {
            Err(TraceRecordError::UnsupportedSchemaVersion {
                found: self.schema_version,
                supported: TRACE_RECORD_SCHEMA_VERSION,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use allbert_proto::{AttributeValue, Span, SpanKind, SpanStatus};
    use chrono::{DateTime, Utc};

    use super::*;

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("fixture timestamp should be valid")
    }

    fn fixture_span() -> Span {
        Span {
            id: "1111111111111111".into(),
            parent_id: None,
            session_id: "repl-primary".into(),
            trace_id: "22222222222222222222222222222222".into(),
            name: "turn".into(),
            kind: SpanKind::Internal,
            started_at: ts(1_774_044_800),
            ended_at: Some(ts(1_774_044_801)),
            duration_ms: Some(1000),
            status: SpanStatus::Ok,
            attributes: BTreeMap::from([(
                "allbert.session.id".into(),
                AttributeValue::String("repl-primary".into()),
            )]),
            events: Vec::new(),
        }
    }

    #[test]
    fn trace_record_roundtrips_schema_version() {
        let record = TraceRecord::span(fixture_span());
        let raw = serde_json::to_string(&record).expect("trace record should serialize");
        assert!(raw.contains(r#""schema_version":1"#));
        assert!(raw.contains(r#""record_type":"span"#));

        let decoded: TraceRecord =
            serde_json::from_str(&raw).expect("trace record should deserialize");
        assert_eq!(decoded, record);
        decoded
            .validate_schema_version()
            .expect("schema version should be supported");
    }

    #[test]
    fn trace_record_rejects_future_schema_version() {
        let mut record = TraceRecord::span(fixture_span());
        record.schema_version = TRACE_RECORD_SCHEMA_VERSION + 1;

        assert_eq!(
            record.validate_schema_version(),
            Err(TraceRecordError::UnsupportedSchemaVersion {
                found: TRACE_RECORD_SCHEMA_VERSION + 1,
                supported: TRACE_RECORD_SCHEMA_VERSION,
            })
        );
    }
}
