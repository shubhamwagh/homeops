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
  const groupName = process.env.GROUP_NAME;
  invariant(groupName, "GROUP_NAME is required");

  const parentGroupName  = process.env.PARENT_GROUP_NAME;
  const groupDescription = process.env.GROUP_DESCRIPTION;

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

    const existing = await kcAdminClient.groups.find({ search: groupName });
    if (existing.some((g) => g.name === groupName)) {
      console.warn(`Group '${groupName}' already exists.`);
      return;
    }

    const groupPayload: Record<string, unknown> = {
      name: groupName,
      ...(groupDescription ? { attributes: { description: [groupDescription] } } : {}),
    };

    if (parentGroupName) {
      const parents = await kcAdminClient.groups.find({ search: parentGroupName });
      const parent = parents.find((g) => g.name === parentGroupName);
      if (!parent) throw new Error(`Parent group '${parentGroupName}' not found`);
      await kcAdminClient.groups.setOrCreateChild({ id: parent.id! }, groupPayload);
      console.log(`Group '${groupName}' created under '${parentGroupName}'.`);
    } else {
      await kcAdminClient.groups.create(groupPayload);
      console.log(`Group '${groupName}' created.`);
    }
  } catch (error) {
    console.error("Error:", error);
    process.exit(1);
  }
};

main();
