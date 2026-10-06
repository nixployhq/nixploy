{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  matches = pattern: value: builtins.match pattern value != null;
  absoluteFile = types.strMatching "/[^[:space:]]+";
  repositoryType = types.addCheck types.str (
    value:
    matches "https://[^/@[:space:]]+/.+" value
    || matches "ssh://[^[:space:]]+/.+" value
    || matches "[^/@:[:space:]]+@[^/:[:space:]]+:[^[:space:]]+" value
  );
  branchType = types.addCheck types.str (
    value:
    value != ""
    && value != "@"
    && !(lib.hasPrefix "-" value)
    && !(lib.hasSuffix "." value)
    && !(lib.hasInfix ".." value)
    && !(lib.hasInfix "@{" value)
    && !(matches ".*[[:space:][:cntrl:]~^:?*].*" value)
    && !(lib.hasInfix "[" value)
    && !(lib.hasInfix "\\" value)
    && lib.all (part: part != "" && !(lib.hasPrefix "." part) && !(lib.hasSuffix ".lock" part)) (
      lib.splitString "/" value
    )
  );
  appModule = {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable deployment and runtime units for this app.";
      };
      repository = mkOption {
        type = repositoryType;
        example = "git@github.com:example/app.git";
        description = "Git repository: HTTPS, ssh://, or user@host:path. Use git.https for HTTPS token authentication.";
      };
      branch = mkOption {
        type = branchType;
        default = "main";
        description = "Git branch name to poll, relative to refs/heads/.";
      };
      package = mkOption {
        type = types.strMatching "[A-Za-z0-9_+-]+";
        default = "default";
        description = "Package name under packages.<host-system>; not a full attribute path.";
      };
      executable = mkOption {
        type = types.addCheck (types.strMatching "[A-Za-z0-9_.+-]+") (value: value != "." && value != "..");
        example = "resolve-tools";
        description = "Required binary name inside the selected package's bin directory; not a path or shell command.";
      };
      pollInterval = mkOption {
        type = types.strMatching "[1-9][0-9]*(s|min|h|d)";
        default = "1min";
        example = "30s";
        description = "Delay after an update attempt completes. Positive integer followed by s, min, h, or d.";
      };
      git = {
        https = {
          username = mkOption {
            type = types.nullOr (types.strMatching "[^[:space:][:cntrl:]:]+");
            default = null;
            example = "git-user";
            description = "Username for HTTPS authentication. Required together with tokenFile; use the value expected by your Git provider.";
          };
          tokenFile = mkOption {
            type = types.nullOr absoluteFile;
            default = null;
            example = "/run/secrets/my-app-git-token";
            description = "Absolute string path to a file containing an HTTPS access token as a single line. Provision outside the Nix store; loaded through systemd credentials at each update.";
          };
        };
        privateKeyFile = mkOption {
          type = types.nullOr absoluteFile;
          default = null;
          example = "/run/secrets/nixploy-github";
          description = "Absolute string path to an existing SSH private key. Provision the file outside the Nix store; never supply its contents here.";
        };
        knownHostsFile = mkOption {
          type = types.nullOr absoluteFile;
          default = null;
          example = "/etc/ssh/ssh_known_hosts";
          description = "Absolute string path to an existing known-hosts file. Required for SSH repositories; host verification must remain enabled.";
        };
      };
      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          HOST = "0.0.0.0";
          PORT = "3000";
        };
        description = "Non-secret application environment variables. These values enter the Nix store.";
      };
    };
  };
in
{
  imports = [ ./runtime.nix ];

  options.services.nixploy.apps = mkOption {
    type = types.attrsOf (types.submodule appModule);
    default = { };
    description = "Applications to deploy. Names use letters, digits, underscores, and hyphens, starting with a letter or digit. No global enable switch is needed.";
  };

  config.assertions = lib.concatLists (
    lib.mapAttrsToList (name: app: [
      {
        assertion = matches "[A-Za-z0-9][A-Za-z0-9_-]*" name;
        message = "services.nixploy.apps: invalid app name '${name}'. Use letters, digits, underscores, and hyphens, starting with a letter or digit.";
      }
      {
        assertion =
          !app.enable || lib.hasPrefix "https://" app.repository || app.git.knownHostsFile != null;
        message = "services.nixploy.apps.${name}.git.knownHostsFile is required for SSH repositories.";
      }
      {
        assertion = !app.enable || ((app.git.https.username == null) == (app.git.https.tokenFile == null));
        message = "services.nixploy.apps.${name}.git.https requires both username and tokenFile.";
      }
      {
        assertion =
          !app.enable
          || app.git.https.tokenFile == null
          || (
            matches "https://[^/@[:space:][:cntrl:]?#]+/[^[:space:][:cntrl:]?#]+" app.repository
            && app.git.privateKeyFile == null
            && app.git.knownHostsFile == null
          );
        message = "services.nixploy.apps.${name}.git.https requires an HTTPS URL without userinfo, query, or fragment, and cannot be combined with SSH credentials.";
      }
      {
        assertion = lib.all (matches "[A-Za-z_][A-Za-z0-9_]*") (builtins.attrNames app.environment);
        message = "services.nixploy.apps.${name}.environment contains an invalid environment variable name.";
      }
    ]) config.services.nixploy.apps
  );
}
