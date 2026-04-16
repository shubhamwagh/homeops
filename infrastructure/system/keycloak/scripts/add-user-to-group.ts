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
  const username = process.env.USERNAME;
  invariant(username, "USERNAME is required");
  const groupName = process.env.GROUP_NAME;
  invariant(groupName, "GROUP_NAME is required");

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

    const users = await kcAdminClient.users.find({ username });
    const user = users.find((u) => u.username === username);
    if (!user) throw new Error(`User '${username}' not found`);

    const groups = await kcAdminClient.groups.find({ search: groupName });
    const group = groups.find((g) => g.name === groupName);
    if (!group) throw new Error(`Group '${groupName}' not found`);

    const userGroups = await kcAdminClient.users.listGroups({ id: user.id! });
    if (userGroups.some((g) => g.id === group.id)) {
      console.log(`User '${username}' is already in group '${groupName}'.`);
      return;
    }

    await kcAdminClient.users.addToGroup({ id: user.id!, groupId: group.id! });
    console.log(`User '${username}' added to group '${groupName}'.`);
  } catch (error) {
    console.error("Error:", error);
    process.exit(1);
  }
};

main();
