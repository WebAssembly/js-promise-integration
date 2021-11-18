# This Makefile uses dune but does not rely on ocamlfind or the Opam
# package manager to build. However, Opam package management is available
# optionally through the install target.
#
# The $(JSLIB).js target requires Js_of_ocaml (using ocamlfind).
#
# See README.me for instructions.


# Configuration

NAME =		wasm
LIB =		$(NAME)
JSLIB =		wast.js
ZIP =		$(NAME).zip

DIRS =		util syntax binary text valid runtime exec script host main tests
LIBS =		bigarray
FLAGS = 	-lexflags -ml -cflags '-w +a-4-27-42-44-45 -warn-error +a-3'
OCBA =		ocamlbuild $(FLAGS) $(DIRS:%=-I %)
OCB =		$(OCBA) $(LIBS:%=-libs %)
JS =		# set to JS shell command to run JS tests


# Main targets

.PHONY:		default opt unopt libopt libunopt jslib all land zip smallint

jslib:		$(JSLIB)
all:		unopt opt libunopt libopt test
land:		$(WINMAKE) all
zip: 		$(ZIP)
smallint:	smallint.native


# Building

.PHONY:		$(NAME) $(JSLIB)

$(NAME):
	rm -f $@
	dune build $@.exe
	ln $(BUILDDIR)/$@.exe $@

$(JSLIB):
	rm -f $@
	dune build $(@:%.js=%.bc.js)
	ln $(BUILDDIR)/$(@:%.js=%.bc.js) $@

.PHONY:		smallint.byte smallint.native
smallint.byte: _tags
		$(OCB) -quiet $@
smallint.native: _tags
		$(OCB) -quiet $@


# Unit tests

FILES =		$(shell ls $(DIRS:%=%/*) | grep '[.]ml[^.]*$$')
PACK =		$(shell echo `echo $(LIB) | sed 's/^\(.\).*$$/\\1/g' | tr [:lower:] [:upper:]``echo $(LIB) | sed 's/^.\(.*\)$$/\\1/g'`)

.INTERMEDIATE:	$(LIB).mlpack
$(LIB).mlpack:	$(DIRS)
		ls $(FILES) \
		| sed 's:\(.*/\)\{0,1\}\(.*\)\.[^\.]*:\2:' \
		| grep -v main \
		| sort | uniq \
		>$@

unittest: $(UNITTESTS:%=unittest/%)

unittest/%:
	dune build $(@F).exe
	dune exec ./$(@F).exe
	@echo All unit tests passed.


# Core test suite

TESTDIR =	../test/core
# Skip _output directory, since that's a tmp directory, and list all other wast files.
TESTFILES =	$(shell cd $(TESTDIR); ls *.wast; ls [a-z]*/*.wast)
TESTS =		$(TESTFILES:%.wast=%)

.PHONY: test partest quiettest

test:		$(OPT) smallint
		$(TESTDIR)/run.py --wasm `pwd`/$(OPT) $(if $(JS),--js '$(JS)',)
		./smallint.native
debugtest:	$(UNOPT) smallint
		$(TESTDIR)/run.py --wasm `pwd`/$(UNOPT) $(if $(JS),--js '$(JS)',)
		./smallint.native

test/%:		$(OPT)
		$(TESTDIR)/run.py --wasm `pwd`/$(OPT) $(if $(JS),--js '$(JS)',) $(TESTDIR)/$*.wast
debugtest/%:	$(UNOPT)
		$(TESTDIR)/run.py --wasm `pwd`/$(UNOPT) $(if $(JS),--js '$(JS)',) $(TESTDIR)/$*.wast

run/%:		$(OPT)
		./$(OPT) $(TESTDIR)/$*.wast
debug/%:	$(UNOPT)
		./$(UNOPT) $(TESTDIR)/$*.wast

partest: $(NAME)
	make -j10 quiettest

quiettest: $(TESTS:%=quiettest/%)
	@echo All tests passed.

quiettest/%: $(NAME)
	@ ( \
	  $(TESTDIR)/run.py 2>$(@F).out --wasm `pwd`/$(NAME) $(if $(JS),--js '$(JS)',) $(TESTDIR)/$*.wast && \
	  rm $(@F).out \
	) || \
	(cat $(@F).out && rm $(@F).out && exit 1)


# Custom test suite

CUSTOMTESTDIR =	../test/custom
CUSTOMTESTDIRS =	$(shell cd $(CUSTOMTESTDIR); ls -d [a-z]*)
CUSTOMTESTFILES =	$(shell cd $(CUSTOMTESTDIR); ls [a-z]*/*.wast)
CUSTOMTESTS =		$(CUSTOMTESTFILES:%.wast=%)
CUSTOMOPTS = -c custom $(CUSTOMTESTDIRS:%=-c %)

.PHONY:		customtest custompartest customquiettest

customtest:		$(NAME)
		$(TESTDIR)/run.py --wasm `pwd`/$(NAME) --opts '$(CUSTOMOPTS)' $(if $(JS),--js '$(JS)',) $(CUSTOMTESTFILES:%=$(CUSTOMTESTDIR)/%)

customtest/%:		$(NAME)
		$(TESTDIR)/run.py --wasm `pwd`/$(NAME) --opts '$(CUSTOMOPTS) ' $(if $(JS),--js '$(JS)',) $(CUSTOMTESTDIR)/$*.wast

customrun/%:		$(NAME)
		./$(NAME) $(CUSTOMOPTS) $(CUSTOMTESTDIR)/$*.wast

custompartest: 	$(CUSTOMTESTS:%=customquiettest/%)
		@echo All custom tests passed.

customquiettest/%:	$(NAME)
		@ ( \
		  $(TESTDIR)/run.py 2>$(@F).out --wasm `pwd`/$(OPT) $(if $(JS),--js '$(JS)',) $(TESTDIR)/$*.wast && \
		  rm $(@F).out \
		) || \
		cat $(@F).out || rm $(@F).out || exit 1

smallinttest:	smallint
		@./smallint.native

# Packaging

.PHONY: install

install:
	dune build -p $(NAME) @install
	dune install

opam-release/%:
	git tag opam-$*
	git push --tags
	rm -f opam-$*.zip
	wget https://github.com/WebAssembly/spec/archive/opam-$*.zip
	cp wasm.opam opam
	echo "url {" >> opam
	echo "  src: \"https://github.com/WebAssembly/spec/archive/opam-$*.zip\"" >> opam
	echo "  checksum: \"md5=`md5 -q opam-$*.zip`\"" >> opam
	echo "}" >> opam
	rm opam-$*.zip
	@echo Created file ./opam, submit to github opam-repository/packages/wasm/wasm.$*/opam

$(ZIP):
	git archive --format=zip --prefix=$(NAME)/ -o $@ HEAD


# Cleanup

.PHONY: clean distclean

clean:
	dune clean

distclean: clean
	rm -f $(NAME) $(JSLIB) $(ZIP)
