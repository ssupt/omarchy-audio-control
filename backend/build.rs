use std::{
    env, fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

fn collect_sources(root: &Path, directory: &Path, files: &mut Vec<String>) {
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_sources(root, &path, files);
        } else if path.is_file() {
            files.push(
                path.strip_prefix(root)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_owned(),
            );
        }
    }
}

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let root = Path::new(&manifest_dir).parent().unwrap();
    let mut files = vec![
        "backend/Cargo.toml".to_owned(),
        "backend/Cargo.lock".into(),
        "backend/build.rs".into(),
        "packaging/manifest.json".into(),
        "packaging/build-release.py".into(),
    ];
    collect_sources(root, &root.join("backend/src"), &mut files);
    println!(
        "cargo:rerun-if-changed={}",
        root.join("backend/src").display()
    );
    collect_sources(root, &root.join("qml"), &mut files);
    println!("cargo:rerun-if-changed={}", root.join("qml").display());
    let scripts = root.join("scripts");
    for entry in fs::read_dir(&scripts).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() && path.file_name().unwrap() != "audio-rust-backend" {
            files.push(
                path.strip_prefix(root)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_owned(),
            );
        }
    }
    println!("cargo:rerun-if-changed={}", scripts.display());
    files.sort();
    let mut source = Vec::new();
    let mut helpers = String::from("pub const HELPERS: &[(&str, &[u8])] = &[\n");
    for name in files {
        println!("cargo:rerun-if-changed={}", root.join(&name).display());
        let bytes = fs::read(root.join(&name)).unwrap();
        source.extend_from_slice(name.as_bytes());
        source.push(0);
        source.extend_from_slice(bytes.len().to_string().as_bytes());
        source.push(0);
        source.extend_from_slice(&bytes);
        if let Some(helper_name) = name.strip_prefix("scripts/") {
            helpers.push_str(&format!(
                "({:?}, include_bytes!({:?})),\n",
                helper_name,
                root.join(&name).to_str().unwrap()
            ));
        }
    }
    helpers.push_str("];\n");
    fs::write(
        Path::new(&env::var("OUT_DIR").unwrap()).join("helpers.rs"),
        helpers,
    )
    .unwrap();
    let mut digest = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("Linux release builds require sha256sum (coreutils)");
    digest.stdin.take().unwrap().write_all(&source).unwrap();
    let digest = digest.wait_with_output().unwrap();
    assert!(digest.status.success());
    let digest = String::from_utf8(digest.stdout).unwrap();
    let digest = digest.split_whitespace().next().unwrap();
    assert_eq!(digest.len(), 64);
    println!("cargo:rustc-env=AUDIO_BUILD_ID={digest}");
    println!(
        "cargo:rustc-env=AUDIO_BUILD_TARGET={}",
        env::var("TARGET").unwrap()
    );
}
