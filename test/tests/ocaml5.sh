#/usr/bin/env bash
set -euo pipefail

opam exec -- ocaml-platform -vv

opam exec -- dune build @doc

ls -l _build/default/_doc/_html/index.html

[[ $(opam exec -- ocamlformat --version) =~ "0.19.0" ]];

opam exec -- dune build @fmt
