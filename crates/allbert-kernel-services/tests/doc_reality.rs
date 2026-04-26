use std::process::Command;

#[test]
fn doc_reality_gate_passes() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("kernel crate should live under crates/");
    let script = repo_root.join("tools/check_doc_reality.sh");

    let output = Command::new(&script)
        .current_dir(repo_root)
        .output()
        .expect("doc reality script should run");

    assert!(
        output.status.success(),
        "doc reality script failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
