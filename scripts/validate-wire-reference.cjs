// Usage: node scripts/validate-wire-reference.cjs NODE_MODULES REQUESTS_JSON SCHEMA_JSON
const fs = require('node:fs');
const path = require('node:path');
const modules = path.resolve(process.argv[2]);
const { RunAgentInputSchema } = require(path.join(modules, '@ag-ui/core/dist/schemas.js'));
const Ajv2020 = require(path.join(modules, 'ajv/dist/2020.js'));
const requests = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const schema = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const ajv = new Ajv2020({ strict: false });
ajv.addSchema(schema, 'agui');
const validate = ajv.getSchema('agui#/$defs/RunAgentInput');
for (const request of requests) {
  RunAgentInputSchema.parse(request);
  if (!validate(request)) throw new Error(JSON.stringify(validate.errors));
}
console.log(`Validated ${requests.length} Swift requests with @ag-ui/core/schemas and schema.json`);
