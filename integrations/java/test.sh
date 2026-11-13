#!/bin/sh
# Compile and run the Java binding's tests with javac and the JUnit jars in the local Maven
# repository (mvn test does the same with a network; see pom.xml).
set -e
cd "$(dirname "$0")"
M=${M2:-$HOME/.m2/repository}
CP=$M/org/junit/jupiter/junit-jupiter-api/5.12.2/junit-jupiter-api-5.12.2.jar
CP=$CP:$M/org/junit/jupiter/junit-jupiter-engine/5.12.2/junit-jupiter-engine-5.12.2.jar
CP=$CP:$M/org/junit/platform/junit-platform-engine/1.12.2/junit-platform-engine-1.12.2.jar
CP=$CP:$M/org/junit/platform/junit-platform-commons/1.12.2/junit-platform-commons-1.12.2.jar
CP=$CP:$M/org/junit/platform/junit-platform-launcher/1.12.2/junit-platform-launcher-1.12.2.jar
CP=$CP:$M/org/opentest4j/opentest4j/1.3.0/opentest4j-1.3.0.jar
CP=$CP:$M/org/apiguardian/apiguardian-api/1.1.2/apiguardian-api-1.1.2.jar
OUT=${TMPDIR:-/tmp}/gnomon-java-$$
rm -rf "$OUT"; mkdir -p "$OUT"
javac -Xlint:all -Werror -d "$OUT" -cp "$CP" $(find src -name '*.java')
java -cp "$OUT:$CP" dev.gnomon.RunTests
rm -rf "$OUT"
