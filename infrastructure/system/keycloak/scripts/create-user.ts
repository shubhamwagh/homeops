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
  const username = process.env.USERNAME;
  invariant(username, "USERNAME environment variable is required");
  const password = process.env.PASSWORD;
  invariant(password, "PASSWORD environment variable is required");

  const email     = process.env.EMAIL;
  const firstName = process.env.FIRST_NAME;
  const lastName  = process.env.LAST_NAME;

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

    const user = await kcAdminClient.users.create({
      username,
      email,
      firstName,
      lastName,
      emailVerified: true,
      enabled: true,
    });
    console.log(`User '${username}' created with ID: ${user.id}`);

    await kcAdminClient.users.resetPassword({
      id: user.id!,
      credential: { type: "password", value: password, temporary: false },
    });
    console.log(`Password set for user '${username}'.`);
  } catch (error) {
    console.error("Error creating user:", error);
    process.exit(1);
  }
};

main();
