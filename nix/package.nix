{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  copyDesktopItems,
  makeDesktopItem,
  cmake,
  gtk3,
  glib,
  dbus,
  libayatana-appindicator,
  fontconfig,
  freetype,
  libx11,
  libxcb,
  libxkbcommon,
  libxext,
  wayland,
  vulkan-loader,
  xdg-utils,
  cacert,
  nyaterm-src,
  githubGistClientId ? null,
}:

# NyaTerm 2.x is a pure-Rust GPUI application: one Cargo workspace builds the
# application and the helper processes it spawns, and every frontend asset is
# embedded by `rust-embed` at compile time. There is no pnpm/Node build step and
# no separate sidecar crate to package.
let
  cargoToml = builtins.fromTOML (builtins.readFile "${nyaterm-src}/Cargo.toml");
  version = cargoToml.workspace.package.version;
  src = lib.cleanSourceWith {
    src = nyaterm-src;
    filter =
      path: type:
      let
        baseName = baseNameOf path;
      in
      !(
        baseName == "target"
        || baseName == ".git"
        || baseName == "result"
        || lib.hasPrefix "result-" baseName
        # Upstream keeps untracked reference checkouts in `temp/` (see the
        # `exclude` list in its Cargo.toml). The pinned source never contains it;
        # pruning it here keeps a local `path:` checkout from changing what the
        # build sees. Nix copies the input tree into the store before this filter
        # runs, so this trims the build, not that initial copy.
        || baseName == "temp"
      );
  };
  icons = "${src}/crates/nyaterm-app/resources/icons";
in
rustPlatform.buildRustPackage {
  pname = "nyaterm";
  inherit version src;

  # The dependency graph is pinned by `Cargo.lock`, but it also contains git
  # dependencies (gpui, russh, IronRDP, ...) whose trees have no checksum in the
  # lock file, so the vendored sources are fetched as one fixed-output
  # derivation. scripts/update-upstream.sh adopts the hash Nix reports.
  cargoHash = "sha256-S50EQYVtgsNIhsPxbX4kHLJr27Xk5M9aDTeE200iWdY=";

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook3
    copyDesktopItems
    # aws-lc-sys configures its C build with CMake. Only the CMake *tool* is
    # wanted here: cargo owns the configure and build phases.
    cmake
  ];

  dontUseCmakeConfigure = true;

  buildInputs = [
    # GPUI renderer, windowing and font backend.
    fontconfig
    freetype
    libx11
    libxcb
    libxkbcommon
    libxext
    wayland
    # Tray icon and native menu integration.
    gtk3
    glib
    libayatana-appindicator
    # `keyring`'s sync-secret-service feature links libdbus through libdbus-sys.
    # It resolves today only because gtk3 propagates at-spi2-core, which
    # propagates dbus; name the input here instead of depending on that chain.
    dbus
  ];

  # Baked into `nyaterm_core::packaging` at compile time: the Nix package owns
  # the update channel, so the application hides its in-app updater and reports
  # the package manager in the About dialog instead of offering an update it
  # cannot apply to a read-only /nix/store installation.
  NYATERM_PACKAGE_MANAGER = "nix";
  NYATERM_GITHUB_GIST_CLIENT_ID = lib.optionalString (githubGistClientId != null) githubGistClientId;

  desktopItems = [
    (makeDesktopItem {
      name = "nyaterm";
      desktopName = "NyaTerm";
      comment = "GPU-accelerated SSH client and terminal workspace";
      exec = "nyaterm %U";
      icon = "nyaterm";
      categories = [
        "System"
        "TerminalEmulator"
      ];
      mimeTypes = [
        "x-scheme-handler/nyaterm"
        "x-scheme-handler/ssh"
        "x-scheme-handler/telnet"
      ];
      startupWMClass = "nyaterm";
    })
  ];

  # `nyaterm` spawns nyaterm-mcp, nyaterm-rdp-helper and nyaterm-vnc-helper from
  # its own directory, which is why all four binaries must stay in $out/bin.
  # (crates/nyaterm-activex-helper is a default member too, but it only uses its
  # Windows dependencies, so the Linux build installs no binary for it.)
  postInstall = ''
    install -Dm 644 ${icons}/32x32.png $out/share/icons/hicolor/32x32/apps/nyaterm.png
    install -Dm 644 ${icons}/64x64.png $out/share/icons/hicolor/64x64/apps/nyaterm.png
    install -Dm 644 ${icons}/128x128.png $out/share/icons/hicolor/128x128/apps/nyaterm.png
    install -Dm 644 ${icons}/256x256.png $out/share/icons/hicolor/256x256/apps/nyaterm.png
    install -Dm 644 ${icons}/512x512.png $out/share/icons/hicolor/512x512/apps/nyaterm.png
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          wayland
          libxkbcommon
          vulkan-loader
          libayatana-appindicator
        ]
      }"
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    )
  '';

  # The upstream suite drives a live GPUI window and real SSH/WebDAV endpoints;
  # it is not hermetic enough for the build sandbox. Upstream CI runs it.
  doCheck = false;

  meta = with lib; {
    description = "GPU-accelerated SSH client and terminal workspace";
    homepage = "https://nyaterm.app";
    license = licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "nyaterm";
  };
}
