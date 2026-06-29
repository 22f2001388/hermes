"use strict";

const DEBUG = /^(1|true|yes)$/i.test(process.env.HERMES_DEBUG || "");

function log(...args) {
  console.log(...args);
}

function debug(...args) {
  if (DEBUG) {
    console.log("[debug]", ...args);
  }
}

module.exports = { log, debug, DEBUG };
