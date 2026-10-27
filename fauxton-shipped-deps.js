// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

// Writes a package.json and package-lock.json listing only the npm packages
// that end up in the Fauxton release bundle, so the dependency scan covers
// what is shipped instead of Fauxton's build and test tooling.
//
// Run from the Fauxton source directory after `npm ci`:
//   node fauxton-shipped-deps.js <output dir>

const fs = require('fs');
const os = require('os');
const path = require('path');
const { createRequire } = require('module');

const outDir = process.argv[2];
if (!outDir) {
  console.error('usage: node fauxton-shipped-deps.js <output dir>');
  process.exit(1);
}

const fauxtonRequire = createRequire(path.join(process.cwd(), 'package.json'));
const webpack = fauxtonRequire('webpack');
const config = fauxtonRequire('./webpack.config.release.js');
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const root = lock.packages[''];

config.output.path = fs.mkdtempSync(path.join(os.tmpdir(), 'fauxton-shipped-'));

// node_modules/a/node_modules/@b/c/lib/x.js -> node_modules/a/node_modules/@b/c
function packageKey(file) {
  const rel = path.relative(process.cwd(), file.split('?')[0]).split(path.sep).join('/');
  const match = rel.match(/^(node_modules\/.*node_modules\/(?:@[^/]+\/)?[^/]+|node_modules\/(?:@[^/]+\/)?[^/]+)/);
  return match && match[1];
}

// Same lookup as Node: nested node_modules first, then each parent up to the top.
function resolve(from, name) {
  let dir = from;
  for (;;) {
    const key = (dir ? dir + '/' : '') + 'node_modules/' + name;
    if (lock.packages[key]) {
      return key;
    }
    if (!dir) {
      return null;
    }
    const idx = dir.lastIndexOf('/node_modules/');
    dir = idx === -1 ? '' : dir.slice(0, idx);
  }
}

// webpack drops buildInfo.fileDependencies once a module is built, so keep a copy.
// For extracted CSS these are the stylesheets (and their @imports) that end up
// in the CSS output, which never show up as modules of their own.
const fileDependencies = new Map();
const compiler = webpack(config);
compiler.hooks.compilation.tap('FauxtonShippedDeps', compilation => {
  webpack.NormalModule.getCompilationHooks(compilation).beforeSnapshot.tap('FauxtonShippedDeps', module => {
    fileDependencies.set(module, [...module.buildInfo.fileDependencies]);
  });
});

compiler.run((err, stats) => {
  if (err || stats.hasErrors()) {
    console.error(err || stats.toString('errors-only'));
    process.exit(1);
  }

  const { compilation } = stats;
  const kept = new Set();
  const keep = file => {
    const key = packageKey(file);
    if (!key) {
      return;
    }
    if (!lock.packages[key]) {
      console.error(`${key} is bundled but missing from package-lock.json`);
      process.exit(1);
    }
    kept.add(key);
  };
  // Only modules that are part of a chunk are emitted; modules that just run
  // during the build (e.g. css-loader's runtime under mini-css-extract) are not.
  for (const module of compilation.modules) {
    if (compilation.chunkGraph.getNumberOfModuleChunks(module) === 0) {
      continue;
    }
    for (const inner of module.modules || [module]) {
      if (inner.resource) {
        keep(inner.resource);
      }
    }
    if (module.type === 'css/mini-extract') {
      const issuer = compilation.moduleGraph.getIssuer(module);
      for (const file of fileDependencies.get(issuer) || []) {
        if (!/\.(c|m)?js$|\.json$/.test(file)) {
          keep(file);
        }
      }
    }
  }

  const packages = {};
  for (const key of [...kept].sort()) {
    const entry = { ...lock.packages[key] };
    delete entry.dev;
    delete entry.devOptional;
    delete entry.peer;
    delete entry.devDependencies;
    for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
      if (!entry[field]) {
        continue;
      }
      const deps = Object.fromEntries(Object.entries(entry[field]).filter(([name]) => kept.has(resolve(key, name))));
      if (Object.keys(deps).length) {
        entry[field] = deps;
      } else {
        delete entry[field];
      }
    }
    packages[key] = entry;
  }

  // Direct dependencies are the bundled packages Fauxton declares itself,
  // plus any bundled top-level package nothing else bundled points to.
  const declared = new Set([...Object.keys(root.dependencies || {}), ...Object.keys(root.devDependencies || {})]);
  const direct = [...kept].filter(key => /^node_modules\/(@[^/]+\/)?[^/]+$/.test(key) && declared.has(key.slice('node_modules/'.length)));
  const reached = new Set();
  const walk = key => {
    if (reached.has(key)) {
      return;
    }
    reached.add(key);
    const entry = packages[key];
    for (const name of Object.keys({ ...entry.dependencies, ...entry.optionalDependencies, ...entry.peerDependencies })) {
      walk(resolve(key, name));
    }
  };
  direct.forEach(walk);
  for (const key of kept) {
    if (reached.has(key)) {
      continue;
    }
    if (key.includes('/node_modules/')) {
      console.error(`${key} is bundled but not reachable from any bundled top-level package`);
      process.exit(1);
    }
    direct.push(key);
    walk(key);
  }

  const dependencies = Object.fromEntries(direct.sort().map(key => [key.slice('node_modules/'.length), packages[key].version]));
  const manifest = {
    name: 'fauxton',
    version: process.env.FAUXTON_VERSION || root.version,
    license: root.license,
    dependencies
  };
  const shippedLock = {
    name: manifest.name,
    version: manifest.version,
    lockfileVersion: 3,
    requires: true,
    packages: { '': manifest, ...packages }
  };

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
  fs.writeFileSync(path.join(outDir, 'package-lock.json'), JSON.stringify(shippedLock, null, 2) + '\n');

  console.log(`Fauxton ships ${kept.size} npm packages (${direct.length} direct):`);
  for (const key of Object.keys(packages)) {
    console.log(`  ${key.slice('node_modules/'.length).split('/node_modules/').join(' > ')}@${packages[key].version}`);
  }
});
