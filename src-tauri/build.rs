fn main() {
    link_libmpv();
    tauri_build::build()
}

fn link_libmpv() {
    if let Ok(dir) = std::env::var("MPV_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
        return;
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = std::process::Command::new("brew")
            .args(["--prefix", "mpv"])
            .output()
        {
            if output.status.success() {
                let prefix = String::from_utf8_lossy(&output.stdout).trim().to_string();
                let lib_dir = std::path::Path::new(&prefix).join("lib");
                if lib_dir.exists() {
                    println!("cargo:rustc-link-search=native={}", lib_dir.display());
                    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
                    return;
                }
            }
        }
    }

    if let Ok(output) = std::process::Command::new("pkg-config")
        .args(["--libs", "mpv"])
        .output()
    {
        if output.status.success() {
            let args = String::from_utf8_lossy(&output.stdout);
            for arg in args.split_whitespace() {
                if let Some(path) = arg.strip_prefix("-L") {
                    println!("cargo:rustc-link-search=native={path}");
                }
            }
            return;
        }
    }

    println!("cargo:warning=libmpv not found. Install mpv with Homebrew or set MPV_LIB_DIR.");
}
