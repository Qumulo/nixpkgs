{ vimUtils, fetchzip }:
vimUtils.buildVimPlugin {
  pname = "qvim";
  version = "2025-03-23";
  src = fetchzip {
    url = "https://gravyweb.eng.qumulo.com/release/7.4.3/src/build/tools/editors/vim.tar.gz";
    hash = "sha256-9ZX2NitOQ6RMvrRSct3zXGYFt8aeKdn4FD4CDYHzM1M=";
    stripRoot = false;
  };
}
