# Two stage: Maven builds a shaded jar, the runtime image carries only a JRE.
# Both base images pinned to an exact patch, not the floating "3.9"/"21"
# tags: this suite exists to produce reproducible figures, and a floating tag
# can change the numbers between runs with no record of why.
FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
# Warm the dependency cache so source edits do not re-download the SDK.
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package

FROM eclipse-temurin:21.0.12_8-jre
WORKDIR /app
COPY --from=build /src/target/harness.jar /app/harness.jar
ENTRYPOINT ["java", "-jar", "/app/harness.jar"]
