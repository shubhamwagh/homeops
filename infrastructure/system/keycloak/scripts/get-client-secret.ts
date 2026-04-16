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
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  invariant(clientId, "KEYCLOAK_CLIENT_ID is required");

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
    kcAdminClient.setConfig({ realmName });

    const clients = await kcAdminClient.clients.find({ clientId });
    if (clients.length === 0) throw new Error(`Client '${clientId}' not found in realm '${realmName}'`);

    const secret = await kcAdminClient.clients.getClientSecret({ id: clients[0].id! });
    // Print only the secret value for easy capture in shell scripts
    console.log(secret.value);
  } catch (error) {
    console.error(`Error:`, error);
    process.exit(1);
  }
};

main();
