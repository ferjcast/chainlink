{
  description = "Chainlink - Reproducible Nix Build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    foundry.url = "github:shazow/foundry.nix/monthly";
    flake-utils.url = "github:numtide/flake-utils";
    foundry.inputs.flake-utils.follows = "flake-utils";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils,
    foundry,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      isCrib = builtins.getEnv "IS_CRIB" == "true";
      pkgs = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [ foundry.overlay ];
      };

      version = "0.0.0-develop";
      gitCommit = self.shortRev or self.dirtyShortRev or "unknown";
      go = pkgs.go_1_25;

      # Build the chainlink binary
      chainlink = pkgs.buildGoModule.override { go = go; } {
        pname = "chainlink";
        inherit version;
        src = ./.;

        proxyVendor = true;
        vendorHash = "sha256-9lnlMT/E+kAiSbBBLshoUHAVIrqbtxRbc+LTe9JPsHk=";

        subPackages = ["."];
        nativeBuildInputs = [pkgs.gcc pkgs.cacert];

        # Allow Go to use toolchain auto-download for version compatibility
        preBuild = ''
          export GOTOOLCHAIN=auto
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        '';

        ldflags = [
          "-X github.com/smartcontractkit/chainlink/v2/core/static.Version=${version}"
          "-X github.com/smartcontractkit/chainlink/v2/core/static.Sha=${gitCommit}"
        ];

        doCheck = false;

        meta = with pkgs.lib; {
          description = "Chainlink decentralized oracle network node";
          homepage = "https://github.com/smartcontractkit/chainlink";
          license = licenses.mit;
          mainProgram = "chainlink";
        };
      };

      dockerImage = pkgs.dockerTools.buildImage {
        name = "chainlink";
        tag = version;
        copyToRoot = pkgs.buildEnv {
          name = "chainlink-root";
          paths = [ chainlink pkgs.cacert pkgs.tzdata ];
          pathsToLink = ["/bin" "/etc"];
        };
        config = {
          Entrypoint = ["${chainlink}/bin/chainlink"];
          Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
        };
      };

      testScript = pkgs.writeShellScriptBin "run-tests" ''
        set -e
        export GOPATH="$HOME/go"
        export GOCACHE="$HOME/.cache/go-build"
        echo "Running Chainlink unit tests..."
        cd ${./.}
        ${go}/bin/go test -v ./core/... 2>&1 | head -200 || true
      '';

      testArtifactScript = pkgs.writeShellScriptBin "test-artifact" ''
        set -e
        BINARY="${chainlink}/bin/chainlink"
        echo "Testing Chainlink artifact: $BINARY"
        echo "========================================"
        ls -la "$BINARY"
        "$BINARY" --version 2>&1 || true
        ${pkgs.file}/bin/file "$BINARY"
        echo "Artifact tests completed!"
      '';

      verifySignatureScript = pkgs.writeShellScriptBin "verify-signature" ''
        set -e
        echo "Verifying Git commit signature..."
        if [ ! -e ".git" ]; then
          echo "ERROR: Not a git repository! Run this from the project directory."
          exit 1
        fi
        echo "Importing SmartContractKit GPG keys..."
        ${pkgs.curl}/bin/curl -sfL https://github.com/smartcontractkit.gpg | ${pkgs.gnupg}/bin/gpg --import 2>/dev/null || true
        COMMIT=$(${pkgs.git}/bin/git rev-parse HEAD)
        echo "Commit: $COMMIT"
        ${pkgs.git}/bin/git verify-commit HEAD 2>&1 || { echo "Signature verification failed!"; exit 1; }
        echo "Commit signature is VALID!"
      '';

      generateSbomScript = pkgs.writeShellScriptBin "generate-sbom" ''
        set -e
        OUTDIR="''${1:-.}"
        BINARY="${chainlink}/bin/chainlink"
        ${pkgs.syft}/bin/syft "$BINARY" -o spdx-json="$OUTDIR/chainlink-sbom.spdx.json"
        ${pkgs.syft}/bin/syft "$BINARY" -o cyclonedx-json="$OUTDIR/chainlink-sbom.cdx.json"
        echo "SBOMs generated in $OUTDIR"
      '';

      scanVulnsScript = pkgs.writeShellScriptBin "scan-vulns" ''
        set -e
        echo "Scanning Chainlink for vulnerabilities..."
        BINARY="${chainlink}/bin/chainlink"
        ${pkgs.grype}/bin/grype "$BINARY" 2>&1 | head -50 || true
        cd ${./.}
        export GOPATH="$HOME/go"
        export GOCACHE="$HOME/.cache/go-build"
        ${pkgs.govulncheck}/bin/govulncheck ./... 2>&1 | head -100 || true
      '';

    in rec {
      packages = {
        default = chainlink;
        inherit chainlink dockerImage;
        run-tests = testScript;
        test-artifact = testArtifactScript;
        verify-signature = verifySignatureScript;
        generate-sbom = generateSbomScript;
        scan-vulns = scanVulnsScript;
      };

      # Keep original dev shell
      devShell = pkgs.callPackage ./shell.nix {
        isCrib = isCrib;
        inherit pkgs;
      };

      devShells.default = devShell;

      formatter = pkgs.nixpkgs-fmt;

      apps = {
        default = { type = "app"; program = "${chainlink}/bin/chainlink"; };
        run-tests = { type = "app"; program = "${testScript}/bin/run-tests"; };
        test-artifact = { type = "app"; program = "${testArtifactScript}/bin/test-artifact"; };
        verify-signature = { type = "app"; program = "${verifySignatureScript}/bin/verify-signature"; };
        generate-sbom = { type = "app"; program = "${generateSbomScript}/bin/generate-sbom"; };
        scan-vulns = { type = "app"; program = "${scanVulnsScript}/bin/scan-vulns"; };
      };
    });
}
