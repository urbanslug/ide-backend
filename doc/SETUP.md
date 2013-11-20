Sandboxes
=========

In order to make sure that ide-backend works even when completely isolated from
ide-backend-server (after all, we want different ide-backend-servers for
different versions of ghc, each with their own package DBs), these instructions
assume the sandbox approach described in
http://www.edsko.net/2013/02/10/comprehensive-haskell-sandboxes/ ; we summarize
the approach below.  It is of course not required to follow that approach; if
using a different approach, these instructions can still help settings things
up, mutatis mutandis.

We have various "sandboxes" (build environments) represented by directories 

    ~/env/fpco-stock-7.4
    ~/env/fpco-patched-7.4
    ~/env/fpco-patched-7.8

a symlink
    
    ~/env/active -> ~/env/fpco-stock-7.4

(or whichever sandbox is "active"). Then we have (non-changing) symlinks

    ~/.ghc   -> ~/env/active/dot-ghc
    ~/.cabal -> ~/env/active/dot-cabal
    ~/local  -> ~/env/active/local

The fpco-stock-7.4 sandbox
--------------------------

This is the sandbox in which we compile the ide-backend client, and the
infrastructure surrounding it. The version of ghc here is not so important;
this could be ghc 7.6 for instance (i.e., it is unrelated to the version that
we use for ide-backend-server). For now we will assume it's a stock 7.4.

* If you want to profile, you may want to set 

      library-profiling: True

  in your ~/.cabal/config.    

* Install:

  - Standard installation of ghc 7.4.2
  - ide-backend/vendor/cabal/Cabal (Cabal-ide-backend)
    (make sure to ghc-pkg hide Cabal-ide-backend)
  - ide-backend and dependencies

The fpco-patched-7.4 sandbox
----------------------------

In this sandbox we will build ide-backend-server for ghc 7.4.

* Set
  
      documentation: True 

  in ~/.cabal/config so that .haddock files are created (these are necessary to
  so that ide-backend-server can create more informative identifier
  information).

  (There is probably not much point in installing profiling libraries in this
  sandbox because the ghc api is not useable in profiling mode.)

* Install

  - Branch "ide-backend-experimental" of ghc (see instructions below)
  - ide-backend/vendor/binary (binary-ide-backend)
    (make sure to ghc-pkg hide binary-ide-backend)
  - ide-backend-server and dependencies (including alex/happy)

* Create package DB for snippets (the "snippet DB")

  The snippet DB is logically independent of the DB used to build
  ide-backend-server: the dependencies of ide-backend-server do not have to be
  available when ide-backend-server runs. (Moreover, it is conceivable that
  ide-backend-server relies on version X of a particular package, but we want
  to make version Y available in the snippet DB.)

  However, the packages in the snippet DB should be compiled with the patched
  ghc (ghci can only load guarantee to libs built by the same ghc instance -- a
  different instance of the same ghc version may work but you're playing with
  fire).

  To initialize the snippet DB use 

      ghc-pkg init /Users/dev/env/fpco-patched-7.4/dot-ghc/snippet-db

  To install packages into the snippet DB use

      cabal install --package-db=clear \
                    --package-db=global \
                    --package-db=/Users/dev/env/fpco-patched-7.4/dot-ghc/snippet-db \
                    --prefix=/Users/dev/env/fpco-patched-7.4/dot-cabal

  (modifying absolute paths as required, of course).  Clearing the package DB
  is necessary so that we do not rely on any dependencies in the user DB (which
  will not be available when ide-backend-server runs); we need to use absolute
  paths here so that we do not rely on the sandbox symlinks pointing to
  specific locations (which may not be true at run-time; see
  http://www.edsko.net/2013/02/10/comprehensive-haskell-sandboxes/ , the last
  section, "Known Limitations"). 
  
  Note that you need to make sure to use absolute paths *even if you do reuse
  the user DB of this sandbox as the snippet DB*; in that case, you may want to
  set

      install-dirs user
        prefix: /Users/dev/env/fpco-patched-7.4/dot-cabal

  in ~/.cabal/config.

  You will want to install

  - ide-backend/rts (required)
  - "parallel", "MonadCatchIO-transformers" and "MonadCatchIO-mtl" for the
    ide-backend test suite (and optionally, "yesod") 
    NOTE: use paralllel-3.2.0.3 (https://github.com/fpco/ide-backend/issues/138)
    NOTE: install MoandCatchIO-transformers before MonadCatchIO-tml
    (https://github.com/fpco/ide-backend/issues/139)
  - whatever other packages you want to be available to snippets at runtime

  (Of course, you could use a separate snippet DB for the test suite.)

The fpco-patched-7.8 sandbox
----------------------------

See instructions for the fpco-patched-7.4 sandbox, but using the patched 7.8
version of ghc instead (see below).

Running the tests
=================

The tests (as well as the ide-backend client library itself) will be compiled
in the fpco-stock-7.4 sandbox, and can be run inside that sandbox (or indeed in
an empty sandbox where no ghc compiler is available on the path at all), as
long as we specify the right paths:

    IDE_BACKEND_EXTRA_PATH_DIRS=~/env/fpco-patched-7.4/local/bin:~/env/fpco-patched-7.4/dot-cabal/bin \
    IDE_BACKEND_PACKAGE_DB=~/env/fpco-patched-7.4/dot-ghc/snippet-db \
    dist/build/ghc-errors/ghc-errors 

(These environment variables are translated by the test-suite to the
corresponding options in SessionConfig, they are *not* part of the ide-backend
library itself.)

Installing the patched versions of ghc
======================================

In order to build ghc, you need ghc; both ghc 7.4 and ghc 7.8 can be built
using the stock 7.4; if using the sandboxes approach, you will want a sandbox
active that contains a stock 7.4 compiler (fpco-stock-7.4 will do).

ghc 7.4
-------

* Get ghc from fpco; in ~/env/fpco-patched-7.4/local/src, run 

      git clone git@github.com:fpco/ghc

* Go to the ghc directory, and checkout the ide-backend branch of 7.4.2:

      git checkout ide-backend-experimental

* Get the 7.4.2 release of the core libraries: 

      ./sync-all --no-dph -r git://git.haskell.org get

* Make sure we're still in the experimental branch of ghc:
  
      git checkout ide-backend-experimental

* Create build.mk

      cp mk/build.mk.sample mk/build.mk

  then make sure to select the "quick" BuildFlavour and that haddocks get
  built (make sure there are no trailing spaces in your build.mk!)

* Build as usual

      perl boot && ./configure && make -j8

* Make the in-place compiler available as normal; i.e. create the following
  symlinks in ~/env/fpco-patched-7.4/local/bin:

      ghc          -> ../src/ghc/inplace/bin/ghc-stage2
      ghc-7.4.2.10 -> ../src/ghc/inplace/bin/ghc-stage2
      ghc-pkg      -> ../src/ghc/inplace/bin/ghc-pkg
      haddock      -> ../src/ghc/inplace/bin/haddock
      hsc2hs       -> ../src/ghc/inplace/bin/hsc2hs

ghc 7.8
-------

TODO