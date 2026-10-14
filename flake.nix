{
  description = "Project Maya: run GLM-5.3-Flash (321B MoE) locally on your own NVIDIA GPUs - NixOS package and service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    maya = {
      url = "github:mw00/project-maya/main";
      flake = false;
    };
    llama-pinned = {
      url = "github:ggml-org/llama.cpp/3cf03257f219afbe7334045ff7c6a06ac68c627d";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, maya, llama-pinned } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      version = builtins.head (nixpkgs.lib.splitString "\n" (builtins.readFile (maya + "/VERSION")));

      ggmlPin = builtins.head (builtins.match "([0-9a-f]+).*"
        (builtins.readFile (maya + "/third_party/ggml/VERSION.txt")));

      pinChecked =
        if (llama-pinned.rev or "") == ggmlPin then true
        else
          throw ''
            Project Maya's source pins llama.cpp/ggml at ${ggmlPin}, but this flake locks llama-pinned at
            ${llama-pinned.rev or "an unknown revision"}.
            Fix: set inputs.llama-pinned.url = "github:ggml-org/llama.cpp/${ggmlPin}" in flake.nix,
            then run: nix flake lock --update-input llama-pinned'';

      mayaPkgs = self.packages.${system};
    in
    {
      overlays.default = final: prev: {
        maya-engine = mayaPkgs.maya-engine;
        maya-vision = mayaPkgs.maya-vision;
        maya-serve = mayaPkgs.maya-serve;
        maya = mayaPkgs.maya-serve;
      };

      packages.${system} = rec {
        maya-engine = pkgs.callPackage ./pkgs/engine.nix {
          inherit version ggmlPin pinChecked;
          src = inputs.maya;
          llamaSrc = inputs.llama-pinned;
        };

        maya-vision = pkgs.callPackage ./pkgs/vision.nix {
          inherit version ggmlPin pinChecked;
          mayaSrc = inputs.maya;
          llamaSrc = inputs.llama-pinned;
        };

        maya-serve = pkgs.callPackage ./pkgs/serve.nix {
          inherit version pinChecked;
          mayaSrc = inputs.maya;
          llamaSrc = inputs.llama-pinned;
          engine = maya-engine;
          vision = maya-vision;
        };

        maya = maya-serve;
        default = maya-serve;
      };

      nixosModules.default = import ./nix/module.nix {
        mayaPkgs = mayaPkgs;
      };

      nixosModules.maya = self.nixosModules.default;

      nixosConfigurations.maya-eval = nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.default
          ({ ... }: {
            boot.isContainer = true;
            system.stateVersion = "26.11";
            services.maya.enable = true;
            services.maya.mockEngine = true;
            services.maya.prefetchOnStart = false;
            services.maya.vision = false;
          })
        ];
      };

      # The real path (download + pack + engine), so the unit and the prefetch command line are evaluated too.
      nixosConfigurations.maya-service-eval = nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.default
          ({ ... }: {
            boot.isContainer = true;
            system.stateVersion = "26.11";
            services.maya = {
              enable = true;
              quant = "Maya-S24";
              context = 32768;
              gpus = [ "0" ];
              parallel = 2;
              draft = "dflash2";
              sampling = { temperature = 1.0; top_p = 0.95; };
              env = { STRATA_GLM_RAM_HEADROOM_GB = "10"; };
              extraEngineArgs = [ "--kv" "q4_0" ];
            };
          })
        ];
      };

      checks.${system} = {
        serve-smoke = pkgs.callPackage ./checks/serve-smoke.nix {
          mayaPkg = mayaPkgs.maya-serve;
        };
        module-vm = pkgs.callPackage ./checks/vm.nix {
          mayaModule = self.nixosModules.default;
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ nixpkgs-fmt ];
      };
    };
}
