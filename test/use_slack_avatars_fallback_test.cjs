'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

let handler;
class HTMLImageElement {
  constructor(fallback) { this.fallback = fallback; }
  hasAttribute(name) { return name === 'data-slackmine-avatar-fallback' && this.fallback !== undefined; }
  getAttribute() { return this.fallback; }
  replaceWith(content) { this.replacement = content; }
}
const document = {
  addEventListener(name, callback, capture) {
    assert.equal(name, 'error');
    assert.equal(capture, true);
    handler = callback;
  },
  createElement(name) {
    assert.equal(name, 'template');
    return { set innerHTML(value) { this.content = { html: value }; } };
  }
};
vm.runInNewContext(fs.readFileSync('assets/javascripts/use_slack_avatars.js', 'utf8'), { document, HTMLImageElement });

const image = new HTMLImageElement('<span class="avatar">AC</span>');
handler({ target: image });
assert.equal(image.replacement.html, '<span class="avatar">AC</span>');
const unrelated = new HTMLImageElement();
handler({ target: unrelated });
assert.equal(unrelated.replacement, undefined);
handler({ target: {} });
console.log('Slack avatar fallback OK');
