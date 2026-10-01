{ lib
, stdenv
, rustPlatform
, fetchPnpmDeps
, pnpmConfigHook
, nodejs
, pnpm_10
, pkg-config
, wrapGAppsHook3
, gtk3
, webkitgtk_4_1
, libsoup_3
, libappindicator-gtk3
, libayatana-appindicator
, librsvg
, openssl
, udev
, xdg-utils
, desktop-file-utils
, cacert
, copyDesktopItems
, makeDesktopItem
, nyaterm-src
, githubGistClientId ? null
,
}:

let
  packageJson = builtins.fromJSON (builtins.readFile "${nyaterm-src}/package.json");
  version = packageJson.version;
  src = lib.cleanSourceWith {
    src = nyaterm-src;
    filter = path: type:
      let
        baseName = baseNameOf path;
      in
        !(
          baseName == "target" ||
          baseName == "node_modules" ||
          baseName == "dist" ||
          baseName == ".git" ||
          lib.hasPrefix "result" baseName
        );
  };

  mcpSidecar = rustPlatform.buildRustPackage {
    pname = "nyaterm-mcp";
    inherit version src;

    cargoLock = {
      lockFile = "${nyaterm-src}/src-tauri/crates/nyaterm-mcp/Cargo.lock";
    };
    cargoRoot = "src-tauri/crates/nyaterm-mcp";
    buildAndTestSubdir = "src-tauri/crates/nyaterm-mcp";

    doCheck = false;
  };

  frontend = stdenv.mkDerivation {
    pname = "nyaterm-frontend";
    inherit version src;

    pnpmDeps = fetchPnpmDeps {
      pname = "nyaterm";
      inherit version src;
      pnpm = pnpm_10;
      fetcherVersion = 4;
      # A fixed hash verifies the fetched package contents.
      hash = "sha256-2Qtar7sVKGGhWR2vQsKH4UyUN7WiOoaqKCZcw6IDD1A=";
    };

    nativeBuildInputs = [
      nodejs
      pnpm_10
      pnpmConfigHook
    ];

    preBuild = ''
      # pnpmConfigHook skips the root postinstall script in the Nix sandbox.
      pnpm run postinstall
    '';

    buildPhase = ''
      runHook preBuild
      pnpm exec tsc
      pnpm exec vite build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist/. $out
      runHook postInstall
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "nyaterm";
  inherit version src;

  cargoLock = {
    lockFile = "${nyaterm-src}/src-tauri/Cargo.lock";
  };
  cargoRoot = "src-tauri";
  cargoBuildFlags = [ "--features=tauri/custom-protocol" ];
  buildAndTestSubdir = "src-tauri";

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook3
    copyDesktopItems
  ];

  buildInputs = [
    gtk3
    webkitgtk_4_1
    libsoup_3
    libappindicator-gtk3
    libayatana-appindicator
    librsvg
    openssl
    udev
  ];

  NYATERM_PACKAGE_MANAGER = "nix";
  NYATERM_GITHUB_GIST_CLIENT_ID = lib.optionalString (githubGistClientId != null) githubGistClientId;

  preBuild = ''
    mkdir -p dist src-tauri/binaries
    cp -r ${frontend}/. dist
    cp ${mcpSidecar}/bin/nyaterm-mcp src-tauri/binaries/nyaterm-mcp
    cp ${mcpSidecar}/bin/nyaterm-mcp src-tauri/binaries/nyaterm-mcp-${stdenv.hostPlatform.rust.rustcTarget}
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "nyaterm";
      desktopName = "NyaTerm";
      comment = "A modern, high-performance SSH client and terminal workspace";
      exec = "nyaterm %U";
      icon = "nyaterm";
      categories = [ "System" "TerminalEmulator" ];
      mimeTypes = [
        "x-scheme-handler/nyaterm"
        "x-scheme-handler/ssh"
        "x-scheme-handler/telnet"
      ];
      startupWMClass = "nyaterm";
    })
  ];

  postInstall = ''
    install -m 755 ${mcpSidecar}/bin/nyaterm-mcp $out/bin/nyaterm-mcp
    install -Dm 644 ${nyaterm-src}/src-tauri/icons/32x32.png $out/share/icons/hicolor/32x32/apps/nyaterm.png
    install -Dm 644 ${nyaterm-src}/src-tauri/icons/128x128.png $out/share/icons/hicolor/128x128/apps/nyaterm.png
    install -Dm 644 ${nyaterm-src}/src-tauri/icons/128x128@2x.png $out/share/icons/hicolor/256x256/apps/nyaterm.png
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : "${lib.makeBinPath [ xdg-utils desktop-file-utils ]}"
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libayatana-appindicator libappindicator-gtk3 ]}"
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    )
  '';

  doCheck = false;

  meta = with lib; {
    description = "A modern, high-performance SSH client built with Tauri and React";
    homepage = "https://nyaterm.app";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "nyaterm";
  };
}
