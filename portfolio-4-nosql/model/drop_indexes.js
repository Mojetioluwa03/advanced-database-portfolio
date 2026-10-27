// Back to the unindexed baseline: drops every secondary index, keeping _id.
// load_catalogue.py drops the whole collection anyway; this is for re-running
// plans/before/ against data you have not reloaded.

db.getSiblingDB("shopstack").catalogue.dropIndexes();
print("secondary indexes dropped; remaining:");
db.getSiblingDB("shopstack").catalogue.getIndexes().forEach(function (ix) {
    print("    " + ix.name + "  " + JSON.stringify(ix.key));
});
