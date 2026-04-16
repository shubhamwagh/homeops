import KcAdminClient from "@keycloak/keycloak-admin-client";
import invariant from "tiny-invariant";

const main = async () => {
  const keycloakHost = process.env.KEYCLOAK_HOST;
  invariant(keycloakHost, "KEYCLOAK_HOST is required");
  const adminUsername = process.env.KEYCLOAK_ADMIN_USER;
  invariant(adminUsername, "KEYCLOAK_ADMIN_USER is required");
  const adminPassword = process.env.KEYCLOAK_ADMIN_PASSWORD;
  invariant(adminPassword, "KEYCLOAK_ADMIN_PASSWORD is required");
  const realmName = process.env.KEYCLOAK_REALM;
  invariant(realmName, "KEYCLOAK_REALM is required");

  // Token settings — homelab defaults: long-lived for convenience
  const accessTokenLifespan = parseInt(process.env.ACCESS_TOKEN_LIFESPAN ?? "43200");  // 12h
  const ssoSessionIdle     = parseInt(process.env.SSO_SESSION_IDLE     ?? "86400");   // 24h
  const ssoSessionMax      = parseInt(process.env.SSO_SESSION_MAX      ?? "604800");  // 7d

  const kcAdminClient = new KcAdminClient({
    baseUrl: `https://${keycloakHost}`,
    realmName: "master",
  });

  try {
    await kcAdminClient.auth({
      username: adminUsername,
      password: adminPassword,
      grantType: "password",
      clientId: "admin-cli",
    });
    console.log("Authentication successful.");

    const existingRealms = await kcAdminClient.realms.find();
    if (existingRealms.some((r) => r.realm === realmName)) {
      console.warn(`Realm '${realmName}' already exists.`);
      return;
    }

    await kcAdminClient.realms.create({
      realm: realmName,
      enabled: true,
      accessTokenLifespan,
      ssoSessionIdleTimeout:         ssoSessionIdle,
      ssoSessionMaxLifespan:         ssoSessionMax,
      offlineSessionIdleTimeout:     ssoSessionIdle,
      offlineSessionMaxLifespanEnabled: true,
      offlineSessionMaxLifespan:     ssoSessionMax,
      clientSessionIdleTimeout:      ssoSessionIdle,
      clientSessionMaxLifespan:      ssoSessionMax,
    });

    console.log(`Realm '${realmName}' created.`);
    console.log(`  Access token lifespan : ${accessTokenLifespan / 3600}h`);
    console.log(`  SSO idle timeout      : ${ssoSessionIdle / 3600}h`);
    console.log(`  SSO max lifespan      : ${ssoSessionMax / 86400}d`);
  } catch (error) {
    console.error("Error:", error);
    process.exit(1);
  }
};

main();
