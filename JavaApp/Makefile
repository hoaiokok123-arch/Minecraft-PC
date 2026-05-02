# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build
LWJGL331_SOURCEDIR := src_lwjgl331

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)
LWJGL331_SOURCES := $(shell find $(LWJGL331_SOURCEDIR) -type f -name '*.java' 2>/dev/null)
LWJGL331_CLASSES := $(LWJGL331_SOURCES:$(LWJGL331_SOURCEDIR)/%.java=$(OUTPUTDIR)/lwjgl331/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)

JAVA_RELEASE ?=

# Add all jars to classpath and allow compiling with private API
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" -XDignore.symbol.file
ifneq ($(JAVA_RELEASE),)
JCFLAGS := -source $(JAVA_RELEASE) -target $(JAVA_RELEASE) $(JCFLAGS)
endif

all: $(TARGETS) $(OUTPUTDIR)/lwjgl-3.3.3.jar $(OUTPUTDIR)/lwjgl-3.3.1.jar
	
# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	$(eval EMPTY_CLASSES := $(shell find $(OUTPUTDIR) -name '*.class' -size 0))
	@if [ -n "$(EMPTY_CLASSES)" ]; then \
		echo "Error: found empty class files in $@: $(EMPTY_CLASSES)"; \
		exit 1; \
	fi

# Rules for building java class
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e
	$(eval TARGET=$(word 2, $(subst /, ,$@)))
	@mkdir -p $(OUTPUTDIR)/classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/classes $<
	@cp $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/

$(LWJGL331_CLASSES): $(OUTPUTDIR)/lwjgl331/%.class: $(LWJGL331_SOURCEDIR)/%.java
	@set -e
	@mkdir -p $(OUTPUTDIR)/lwjgl331_classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/lwjgl331_classes $<
	@cp $(@:$(OUTPUTDIR)/lwjgl331/%.class=$(OUTPUTDIR)/lwjgl331_classes/%*.class) $(dir $@)/

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

$(OUTPUTDIR)/lwjgl.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@rm -rf $(OUTPUTDIR)/lwjgl_lib
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib
	@cd $(OUTPUTDIR)/lwjgl_lib && find ../../libs/lwjgl -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib/
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib .

$(OUTPUTDIR)/lwjgl-3.3.3.jar: $(OUTPUTDIR)/lwjgl.jar
	@set -e
	@echo "Creating $@"
	@cp $< $@

$(OUTPUTDIR)/lwjgl-3.3.1.jar: $(CLASSES) $(LWJGL331_CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@rm -rf $(OUTPUTDIR)/lwjgl_lib_3.3.1
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_3.3.1
	@cd $(OUTPUTDIR)/lwjgl_lib_3.3.1 && find ../../libs/lwjgl-3.3.1 -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib_3.3.1/
	@if [ -d $(OUTPUTDIR)/lwjgl331 ]; then cp -R $(OUTPUTDIR)/lwjgl331/* $(OUTPUTDIR)/lwjgl_lib_3.3.1/; fi
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_3.3.1 .

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean
