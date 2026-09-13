const catalog = db.getSiblingDB("FiapCloudGamesCatalog");
catalog.createUser({
  user: "fcg-catalog",
  pwd: process.env.FCG_MONGODB_PASSWORD,
  roles: [{ role: "readWrite", db: "FiapCloudGamesCatalog" }]
});
