#!/usr/bin/env node
/**
 * Copyright (c) HashiCorp, Inc.
 * SPDX-License-Identifier: MPL-2.0
 */

/* eslint-disable */
// run this script via yarn in the ui directory:
// yarn gen-story-md some-component
//
// or if the story is for a component in an in-repo-addon or an engine:
// yarn gen-story-md some-component name-of-engine

const fs = require('fs');
const jsdoc2md = require('jsdoc-to-markdown');
var args = process.argv.slice(2);
const name = args[0];
const addonOrEngine = args[1];
const inputFile = addonOrEngine
  ? `lib/${addonOrEngine}/addon/components/${name}.js`
  : `app/components/${name}.js`;
const outputFile = addonOrEngine ? `lib/${addonOrEngine}/stories/${name}.md` : `stories/${name}.md`;

const component = name
  .split('-')
  .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
  .join('');
const options = {
  files: inputFile,
  template: fs.readFileSync('./lib/story-md.hbs', 'utf8'),
  'example-lang': 'js',
};
let md = jsdoc2md.renderSync(options);

const pageBreakIndex = md.lastIndexOf('---'); //this is our last page break

const seeLinks = `**See**
- [Uses of ${component}](https://github.com/lf-edge/openbao/search?l=Handlebars&q=${component}+OR+${name})
- [${component} Source Code](https://github.com/lf-edge/openbao/blob/main/ui/${inputFile})
`;
const generatedWarning = `<!--THIS FILE IS AUTO GENERATED. This file is generated from JSDoc comments in ${inputFile}. To make changes, first edit that file and run "yarn gen-story-md ${name}" to re-generate the content.-->
`;
md = generatedWarning + md.slice(0, pageBreakIndex) + seeLinks + md.slice(pageBreakIndex);

fs.writeFileSync(outputFile, md);
