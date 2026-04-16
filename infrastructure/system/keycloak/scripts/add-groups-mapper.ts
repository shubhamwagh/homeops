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
    const client = clients.find((c) => c.clientId === clientId);
    if (!client) throw new Error(`Client '${clientId}' not found`);

    const existing = await kcAdminClient.clients.listProtocolMappers({ id: client.id! });
    if (existing.some((m) => m.name === "groups" || m.config?.["claim.name"] === "groups")) {
      console.log("Groups mapper already exists.");
      return;
    }

    await kcAdminClient.clients.addProtocolMapper({ id: client.id! }, {
      name: "groups",
      protocol: "openid-connect",
      protocolMapper: "oidc-group-membership-mapper",
      config: {
        "claim.name":          "groups",
        "full.path":           "false",
        "id.token.claim":      "true",
        "access.token.claim":  "true",
        "userinfo.token.claim":"true",
      },
    });
    console.log(`Groups mapper added to client '${clientId}'.`);
  } catch (error) {
    console.error("Error adding groups mapper:", error);
    process.exit(1);
  }
};

main();
