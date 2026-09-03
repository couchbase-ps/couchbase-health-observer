# Two stage: Maven builds a shaded jar, the runtime image carries only a JRE.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
# Warm the dependency cache so source edits do not re-download the SDK.
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/harness.jar /app/harness.jar
ENTRYPOINT ["java", "-jar", "/app/harness.jar"]
