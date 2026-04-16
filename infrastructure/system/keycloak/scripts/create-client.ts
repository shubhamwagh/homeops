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
  const redirectUrl = process.env.KEYCLOAK_REDIRECT_URL;
  invariant(redirectUrl, "KEYCLOAK_REDIRECT_URL environment variable is required");

  const clientSecret          = process.env.KEYCLOAK_CLIENT_SECRET;
  const redirectUris          = redirectUrl.split(",").map((u) => u.trim());
  const sessionIdle           = process.env.KEYCLOAK_CLIENT_SESSION_IDLE;
  const sessionMax            = process.env.KEYCLOAK_CLIENT_SESSION_MAX;
  const directAccessGrants    = process.env.KEYCLOAK_CLIENT_DIRECT_ACCESS_GRANTS;
  const pkceMethod            = process.env.KEYCLOAK_CLIENT_PKCE_METHOD;
  const postLogoutRedirectUris = process.env.KEYCLOAK_POST_LOGOUT_REDIRECT_URIS;
  const accessTokenLifespan   = process.env.KEYCLOAK_ACCESS_TOKEN_LIFESPAN;

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

    const existingClients = await kcAdminClient.clients.find({ clientId });
    if (existingClients.length > 0) {
      console.warn(`Client '${clientId}' already exists.`);
      return;
    }

    const isPublicClient = !clientSecret || clientSecret === "";
    const clientConfig: Record<string, unknown> = {
      clientId,
      secret: clientSecret,
      enabled: true,
      redirectUris,
      publicClient: isPublicClient,
      directAccessGrantsEnabled: directAccessGrants === "true",
      attributes: {} as Record<string, string>,
    };
    const attrs = clientConfig.attributes as Record<string, string>;

    if (pkceMethod === "S256" || pkceMethod === "plain") {
      attrs["pkce.code.challenge.method"] = pkceMethod;
      console.log(`Setting PKCE Code Challenge Method to ${pkceMethod}`);
    }
    if (sessionIdle)            attrs["client.session.idle.timeout"]  = sessionIdle;
    if (sessionMax)             attrs["client.session.max.lifespan"]  = sessionMax;
    if (accessTokenLifespan)    attrs["access.token.lifespan"]        = accessTokenLifespan;
    if (postLogoutRedirectUris) {
      attrs["post.logout.redirect.uris"] = postLogoutRedirectUris
        .split(",")
        .map((u) => u.trim())
        .join("##");
    }

    const created = await kcAdminClient.clients.create(clientConfig);
    console.log(`Client '${clientId}' created with ID: ${created.id}`);
  } catch (error) {
    console.error("An error occurred:", error);
    process.exit(1);
  }
};

main();
