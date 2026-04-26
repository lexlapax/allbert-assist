use std::path::PathBuf;

pub struct TraceHandles {
    pub guard: Option<Box<dyn Send + Sync>>,
    pub file_path: Option<PathBuf>,
}
