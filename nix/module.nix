{ mayaPkgs }:
{ pkgs, config, lib, ... }:
let
  cfg = config.services.maya;
in
{
  options.services.maya = {
    enable = lib.mkEnableOption "Project Maya, a local OpenAI/Anthropic-compatible API for GLM-5.3-Flash (321B MoE)";

    package = lib.mkPackageOption mayaPkgs "maya" { };

    quant = lib.mkOption {
      type = lib.types.enum [ "Maya-S-v2-IQ2_XXS" "Maya-S24" "Maya-M" "Maya-M-Derisked" "Maya-L" ];
      default = "Maya-S24";
      description = ''
        Which quant to download: `Maya-S24` (the one for cards of 24 GB or less), `Maya-S-v2-IQ2_XXS`
        (upstream's default, the compact quant), `Maya-M`, `Maya-M-Derisked` (experimental) or `Maya-L`.
        Between 95 and 157 GB, downloaded at first start into the service's state directory.
      '';
    };

    context = lib.mkOption {
      type = lib.types.enum [ 8192 32768 65536 131072 ];
      default = 32768;
      description = "Context window in tokens. The model itself goes to 1 M; RAM is what limits it here.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address. Use 0.0.0.0 to serve the LAN (requires apiKeyFile).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File holding the API key (read through a systemd credential, never in the unit).";
    };

    hfTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File holding a Hugging Face token (only for gated model repos).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    gpus = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        CUDA device numbers (as nvidia-smi numbers them, PCI order).
        Empty: the engine picks the card with the most VRAM.
        Several: layer split across the cards (`layerSplit` decides where it cuts).
      '';
    };

    layerSplit = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "With several GPUs: \"auto\", or the first layer of each later card's share (e.g. \"18\" or \"16,32\").";
    };

    parallel = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 4;
      description = "Several requests answered at once (up to 8); each one keeps its own context in VRAM.";
    };

    draft = lib.mkOption {
      type = lib.types.enum [ "mtp" "dflash2" ];
      default = "mtp";
      description = ''
        Drafting: `mtp` (the quant's own MTP block, nothing to download) or `dflash2`
        (a small block drafter fetched from Hugging Face, CC BY-NC-ND 4.0, non-commercial use only;
        it only pays off when the whole model is close, so measure it on your machine).
      '';
    };

    vision = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Images: the server starts the vision encoder in GPU memory the model lends it, and fetches the
        encoder's files (1.1 GB) with the model. False: text only.
      '';
    };

    kvStreaming = lib.mkOption {
      type = lib.types.enum [ "on" "off" ];
      default = "on";
      description = "Keep each attention layer's latent cache in RAM with a window of it in VRAM, so VRAM holds more experts.";
    };

    prefill = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Prompt chunk: \"auto\" (the largest the expert pool can lend, up to 8192) or a number such as \"32768\".";
    };

    sampling = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = { temperature = 1.0; top_p = 0.95; };
      description = "Sampling defaults for requests that leave the fields out (upstream: temperature 1.0, top_p 0.95).";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        MCP servers for the web app's chat, in Claude Desktop's format.
        They run with this service's rights; only add ones you trust.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { STRATA_GLM_RAM_HEADROOM_GB = "10"; };
      description = "Engine environment (STRATA_GLM_*): the RAM headroom, the CPU lane, the prompt sub-batches ...";
    };

    extraEngineArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to the engine command line (e.g. [ \"--kv\" \"q4_0\" ]).";
    };

    mockEngine = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Serve a scripted mock engine instead of the model (tests; no GPU, no download).";
    };

    prefetchOnStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Download/prepare missing model files before starting (resumable, skipped when done).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.host == "127.0.0.1" || cfg.host == "localhost" || cfg.apiKeyFile != null;
        message = "services.maya: exposing the API beyond loopback requires apiKeyFile.";
      }
      {
        assertion = !cfg.mockEngine || !cfg.prefetchOnStart;
        message = "services.maya: mockEngine requires prefetchOnStart = false.";
      }
      {
        assertion = !cfg.mockEngine || !cfg.vision;
        message = "services.maya: mockEngine serves text only; set vision = false with it.";
      }
      {
        assertion = cfg.mockEngine || (cfg.package ? passthru.engine);
        message = "services.maya: package must be the maya-serve bundle (it carries the engine under passthru.engine).";
      }
      {
        assertion = cfg.mockEngine || !cfg.vision || (cfg.package ? passthru.vision);
        message = "services.maya: with vision on, package must carry the vision encoder under passthru.vision.";
      }
      {
        assertion = cfg.parallel == null || (cfg.parallel >= 1 && cfg.parallel <= 8);
        message = "services.maya: parallel is between 1 and 8 (the engine's own limit).";
      }
    ];

    systemd.services.maya = {
      description = "Project Maya: GLM-5.3-Flash (321B MoE) local inference API";
      documentation = [ "https://github.com/mw00/project-maya" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ cfg.package ];

      environment = lib.optionalAttrs (cfg.gpus != [ ])
        {
          CUDA_DEVICE_ORDER = "PCI_BUS_ID";
          CUDA_VISIBLE_DEVICES = lib.concatStringsSep "," cfg.gpus;
        } // cfg.env;

      preStart = lib.mkIf (cfg.prefetchOnStart && !cfg.mockEngine) (toString (
        pkgs.writeShellScript "maya-prestart" (''
          set -euo pipefail
          state="$STATE_DIRECTORY"
          exec ${cfg.package}/bin/maya-prefetch \
            --quant ${lib.escapeShellArg cfg.quant} \
            --context ${toString cfg.context} \
            --data-dir "$state" \
            --draft ${lib.escapeShellArg cfg.draft} \
            --vision ${if cfg.vision then "on" else "off"} \
            --kv-streaming ${lib.escapeShellArg cfg.kvStreaming} \
            --prefill ${lib.escapeShellArg cfg.prefill} \
        '' + lib.optionalString (cfg.parallel != null) ''
          --parallel ${toString cfg.parallel} \
        '' + lib.optionalString cfg.vision ''
          --vision-exe ${lib.escapeShellArg (toString cfg.package.passthru.vision)}/bin/strata-vision \
        '' + lib.optionalString (cfg.hfTokenFile != null) ''
          --hf-token-file "/run/credentials/maya.service/hf-token" \
        '' + ''
          --emit-config "$state/config.json" \
          --engine ${lib.escapeShellArg (toString cfg.package.passthru.engine)}/bin/strata \
          --host ${lib.escapeShellArg cfg.host} \
        '' + lib.optionalString (cfg.apiKeyFile != null) ''
          --api-key-file "/run/credentials/maya.service/api-key" \
        '' + lib.optionalString (cfg.gpus != [ ]) ''
          --gpu ${lib.escapeShellArg (lib.concatStringsSep "," cfg.gpus)} \
        '' + lib.optionalString (cfg.sampling != { }) ''
          --sampling-json ${pkgs.writeText "maya-sampling.json" (builtins.toJSON cfg.sampling)} \
        '' + lib.optionalString (cfg.mcpServers != { }) ''
          --mcp-json ${pkgs.writeText "maya-mcp.json" (builtins.toJSON cfg.mcpServers)} \
        '' + lib.concatMapStrings (x: ''--extra-arg ${lib.escapeShellArg x} '')
          (cfg.extraEngineArgs ++ lib.optionals (cfg.layerSplit != "auto") [ "--layer-split" cfg.layerSplit ])
        )
      ));

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "maya";
        StateDirectoryMode = "0750";
        # First start: preStart downloads ~100 GB, verifies every sha256 and builds the pack - the
        # default 90 s TimeoutStartSec kills it mid-download (the service is resumable, but converge
        # it in one pass). Applies to the start, incl. ExecStartPre.
        TimeoutStartSec = "0";
        WorkingDirectory = "%S/maya";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 10;
        LoadCredential =
          (lib.optional (cfg.apiKeyFile != null) "api-key:${cfg.apiKeyFile}")
          ++ (lib.optional (cfg.hfTokenFile != null) "hf-token:${cfg.hfTokenFile}");
        ExecStart =
          if cfg.mockEngine
          then
            "${cfg.package}/bin/maya-serve --engine mock --port ${toString cfg.port} " +
            "--host ${lib.escapeShellArg cfg.host}"
          else
            "${cfg.package}/bin/maya-serve --engine strata --config %S/maya/config.json " +
            "--port ${toString cfg.port}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
