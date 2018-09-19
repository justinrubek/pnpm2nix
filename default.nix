{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, node-gyp ? nodePackages.node-gyp
} @modArgs:

# Scope mkPnpmDerivation
with (import ./derivation.nix {
     inherit pkgs nodejs nodePackages node-gyp;
});
with pkgs;

let

  rewriteShrinkWrap = import ./shrinkwrap.nix {
    inherit pkgs nodejs nodePackages;
  };

  importYAML = name: yamlFile: (lib.importJSON ((pkgs.runCommandNoCC name {} ''
    mkdir -p $out
    ${pkgs.yaml2json}/bin/yaml2json < ${yamlFile} | ${pkgs.jq}/bin/jq -a '.' > $out/shrinkwrap.json
  '').outPath + "/shrinkwrap.json"));

  overrideDrv = (overrides: drv:
    if (lib.hasAttr drv.pname overrides) then
      (overrides."${drv.pname}" drv)
        else drv);

in {

  # Create a nix-shell friendly development environment
  mkPnpmEnv = drv: let
    envDrv = (drv.override {linkDevDependencies = true;}).overrideAttrs(oldAttrs: {
      propagatedBuildInputs = [
        # Avoid getting npm and its deps in environment
        (drv.passthru.nodejs.override { enableNpm = false; })
        # Users probably want pnpm
        nodePackages.pnpm
      ];
      # Remove original nodejs from inputs, it's now propagated and stripped from npm
      buildInputs = builtins.filter (x: x != drv.passthru.nodejs) oldAttrs.buildInputs;
      # Only keep package.json from sources, we dont need the rest to make the env
      src = lib.cleanSourceWith {
        filter = (name: type: baseNameOf (toString name) == "package.json");
        src = oldAttrs.src; };
      outputs = [ "out" ];
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out
        mv node_modules $out
      '';
    });
  in makeSetupHook {
    deps = envDrv.buildInputs ++ envDrv.propagatedBuildInputs;
  } (writeScript "pnpm-env-hook.sh" ''
    export NODE_PATH=${lib.getLib envDrv}/node_modules
  '');

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    overrides ? {},
    allowImpure ? false,
    linkDevDependencies ? false,
    ...
  } @args:
  let
    specialAttrs = [ "src" "packageJSON" "shrinkwrapYML" "overrides" "allowImpure" ];

    package = lib.importJSON packageJSON;
    pname = package.name;
    version = package.version;
    name = pname + "-" + version;

    shrinkwrap = let
      shrink = importYAML "${pname}-shrinkwrap-${version}" shrinkwrapYML;
    in rewriteShrinkWrap shrink;

    # Convert pnpm package entries to nix derivations
    packages = let

      # Normal (registry/git) packages
      nonLocalPackages = lib.mapAttrs (n: v: (let
        drv = mkPnpmModule v;
        overriden = overrideDrv overrides drv;
      in overriden)) shrinkwrap.packages;

      # Local (link:) packages
      localPackages = let
        attrNames = builtins.filter (a: lib.hasPrefix "link:" a) shrinkwrap.dependencies;
        # Get back original module names
        specifiers = lib.filterAttrs (n: v: lib.elem v attrNames) shrinkwrap.specifiers;
        # Reverse name/values so the rewritten shrinkwrap can find derivations
        revSpecifiers = lib.listToAttrs
          (lib.mapAttrsToList (n: v: lib.nameValuePair v n) specifiers);
      in lib.mapAttrs (n: v: let
        # Note: src can only be local path for link: dependencies
        pkgPath = src + "/" + (lib.removePrefix "link:" n);
        pkg = ((import ./default.nix modArgs).mkPnpmPackage {
          src = pkgPath;
          packageJSON = pkgPath + "/package.json";
          shrinkwrapYML = pkgPath + "/shrinkwrap.yaml";
        }).overrideAttrs(oldAttrs: {
          src = wrapRawSrc pkgPath oldAttrs.pname;
        });
      in pkg) revSpecifiers;
    in nonLocalPackages // localPackages;

    # Wrap sources in a directory named the same as the node_modules/ path
    wrapRawSrc = src: pname: (stdenv.mkDerivation (let
      name = lib.replaceStrings [ "@" "/" ] [ "" "-" ] pname;
    in {
      name = "pnpm2nix-source-${name}";
      inherit src;
      dontBuild = true;
      fixupPhase = ":";
      installPhase = ''
        mkdir -p $out/${pname}
        cp -a * $out/${pname}/
      '';
    }));
    wrapSrc = pkgInfo: let
      integrity = lib.splitString "-" pkgInfo.resolution.integrity;
      shaType = lib.elemAt integrity 0;
      shaSum = lib.elemAt integrity 1;
      tarball = (lib.lists.last (lib.splitString "/" pkgInfo.pname)) + "-" + pkgInfo.version + ".tgz";
      src = (if (lib.hasAttr "integrity" pkgInfo.resolution) then
        (pkgs.fetchurl {
          url = if (lib.hasAttr "tarball" pkgInfo.resolution)
            then pkgInfo.resolution.tarball
            else "${shrinkwrap.registry}${pkgInfo.pname}/-/${tarball}";
            "${shaType}" = shaSum;
        }) else if allowImpure then fetchTarball {
          # Note: Resolved tarballs(github revs for example)
          # does not yet have checksums
          # https://github.com/pnpm/pnpm/issues/1035
          url = pkgInfo.resolution.tarball;
        } else throw "No download method found");
    in wrapRawSrc src pkgInfo.pname;

    mkPnpmModule = pkgInfo: let
      hasCycle = (builtins.length pkgInfo.constituents) > 1;

      # These attrs have already been created in pre-processing
      # Cyclic dependencies has deterministic ordering so they will end up with the exact same attributes
      name = lib.concatStringsSep "-" (builtins.map (attr: shrinkwrap.packages."${attr}".name) pkgInfo.constituents);
      version = if !hasCycle then pkgInfo.version else "cyclic";
      pname = lib.concatStringsSep "-" (builtins.map (attr: shrinkwrap.packages."${attr}".pname) pkgInfo.constituents);

      srcs = (builtins.map (attr: wrapSrc shrinkwrap.packages."${attr}") pkgInfo.constituents);

      deps = builtins.map (attrName: packages."${attrName}")
        # Get all dependencies from cycle
        (lib.unique (lib.flatten (builtins.map
          (attr: shrinkwrap.packages."${attr}".dependencies) pkgInfo.constituents)));

    in
      mkPnpmDerivation {
        inherit deps;
        attrs = { inherit name srcs pname version; };
        linkDevDependencies = false;
      };

  in
    assert shrinkwrap.shrinkwrapVersion == 3;
  (mkPnpmDerivation {
    deps = (builtins.map
      (attrName: packages."${attrName}")
      (shrinkwrap.dependencies ++ shrinkwrap.optionalDependencies));

    devDependencies = builtins.map
      (attrName: packages."${attrName}") shrinkwrap.devDependencies;

    inherit linkDevDependencies;

    # Filter "special" attrs we know how to interpret, merge rest to drv attrset
    attrs = ((lib.filterAttrs (k: v: !(lib.lists.elem k specialAttrs)) args) // {
      srcs = [ (wrapRawSrc src pname) ];
      inherit name pname version;
    });
  });

}
