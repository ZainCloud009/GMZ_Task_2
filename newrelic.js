'use strict';

/**
 * New Relic Agent Configuration for GMZ Cloud Health & Tasks App
 */
exports.config = {
  /**
   * Application name as it will appear in New Relic APM Dashboard
   */
  app_name: [process.env.NEW_RELIC_APP_NAME || 'GMZ-Health-App-Production'],

  /**
   * New Relic Ingestion License Key
   */
  license_key: process.env.NEW_RELIC_LICENSE_KEY,

  logging: {
    level: process.env.NEW_RELIC_LOG_LEVEL || 'info',
    filepath: 'stdout'
  },

  /**
   * Application Logging: Forward all live console logs to New Relic Logs dashboard
   */
  application_logging: {
    enabled: true,
    forwarding: {
      enabled: true,
      max_samples_stored: 10000
    },
    metrics: {
      enabled: true
    },
    local_decorating: {
      enabled: true
    }
  },

  allow_all_headers: true,

  attributes: {
    exclude: [
      'request.headers.cookie',
      'request.headers.authorization',
      'request.headers.proxyAuthorization',
      'request.headers.setCookie*',
      'request.headers.x*'
    ]
  },

  distributed_tracing: {
    enabled: true
  }
};
