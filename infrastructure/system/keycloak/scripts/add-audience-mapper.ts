import KcAdminClient from "@keycloak/keycloak-admin-client";
import invariant from "tiny-invariant";

const main = async () => {
  const keycloakHost = process.env.KEYCLOAK_HOST;
  invariant(keycloakHost, "KEYCLOAK_HOST environment variable is required.");
  const adminUsername = process.env.KEYCLOAK_ADMIN_USER;
  invariant(adminUsername, "KEYCLOAK_ADMIN_USER environment variable is required.");
  const adminPassword = process.env.KEYCLOAK_ADMIN_PASSWORD;
  invariant(adminPassword, "KEYCLOAK_ADMIN_PASSWORD environment variable is required");
  const realmName = process.env.KEYCLOAK_REALM;
  invariant(realmName, "KEYCLOAK_REALM environment variable is required");
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  invariant(clientId, "KEYCLOAK_CLIENT_ID environment variable is required");
  const audience = process.env.KEYCLOAK_AUDIENCE;
  invariant(audience, "KEYCLOAK_AUDIENCE environment variable is required");

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
    kcAdminClient.setConfig({ realmName });

    const clients = await kcAdminClient.clients.find({ clientId });
    if (clients.length === 0) throw new Error(`Client '${clientId}' not found.`);
    const client = clients[0];
    invariant(client.id, "Client ID is not set");

    const mapperName = `aud-mapper-${audience}`;
    const existing = await kcAdminClient.clients.listProtocolMappers({ id: client.id });
    if (existing.some((m) => m.name === mapperName)) {
      console.warn(`Audience mapper '${mapperName}' already exists.`);
      return;
    }

    await kcAdminClient.clients.addProtocolMapper({ id: client.id }, {
      name: mapperName,
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      config: {
        "included.client.audience": audience,
        "id.token.claim":     "false",
        "access.token.claim": "true",
      },
    });
    console.log(`Audience mapper '${mapperName}' added to client '${clientId}'.`);
  } catch (error) {
    console.error("An error occurred:", error);
    process.exit(1);
  }
};

main();
