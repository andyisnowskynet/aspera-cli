# define common variables to be used in other Makefiles
# required: DIR_TOP (can be empty if cwd)
DIR_BIN=$(DIR_TOP)bin/
DIR_LIB=$(DIR_TOP)lib/
DIR_TMP=$(DIR_TOP)tmp/
DIR_PRIV=$(DIR_TOP)local/
DIR_TST=$(DIR_TOP)tests/
DIR_DOC=$(DIR_TOP)docs/

# configuration file used for tests, template is generated in "docs"
TEST_CONF_FILE_BASE=test_env.conf

# this is the actual conf file, create your own from template located in "docs"
TEST_CONF_FILE_PATH=$(DIR_PRIV)$(TEST_CONF_FILE_BASE)
TMPL_CONF_FILE_PATH=$(DIR_DOC)$(TEST_CONF_FILE_BASE)

# just the name of the command line tool as in bin folder
# (used for documentation and execution)
# must be same value as Aspera::Cli::PROGRAM_NAME
EXENAME=ascli

# how tool is called without argument
# use only if another config file is used
# else use EXE_MAN or EXE_NOMAN
EXETESTB=$(DIR_BIN)$(EXENAME)

GEMSPEC=$(DIR_TOP)$(GEMNAME).gemspec

# must be first target
all::

#GEMNAME=$(shell $(EXETESTB) conf gem name)
#GEMVERS=$(shell $(EXETESTB) conf gem version)
$(DIR_TOP)nameversion.mak: $(DIR_LIB)aspera/cli/info.rb $(DIR_LIB)aspera/cli/version.rb
	sed -n "s/.*GEM_NAME = '\([^']*\)'.*/GEMNAME=\1/p" $(DIR_LIB)aspera/cli/info.rb > $@
	sed -n "s/.*'\([^']*\)'.*/GEMVERS=\1/p" $(DIR_LIB)aspera/cli/version.rb >> $@
include $(DIR_TOP)nameversion.mak
PATH_GEMFILE=$(DIR_TOP)$(GEMNAME)-$(GEMVERS).gem
# gem file is generated in top folder
clean::
	rm -f $(DIR_TOP)nameversion.mak

clean::

$(DIR_TMP).exists:
	mkdir -p $(DIR_TMP)
	@touch $@
$(TEST_CONF_FILE_PATH):
	mkdir -p $(DIR_PRIV)
	cp $(TMPL_CONF_FILE_PATH) $(TEST_CONF_FILE_PATH)
	@echo "\033[0;32mAn empty configuration file is created:\n$$(realpath $(TEST_CONF_FILE_PATH))\nIt needs to be filled to run tests.\033[0;39m"
# ensure required ruby gems are installed
$(DIR_TOP).gems_checked: $(DIR_TOP)Gemfile
	cd $(DIR_TOP). && bundle install
	rm -f $$HOME/.rvm/gems/*/bin/as{cli,ession}
	touch $@
clean::
	rm -f $(DIR_TOP).gems_checked
