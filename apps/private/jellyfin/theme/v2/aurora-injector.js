/* MSP UI v2 - Aurora palette TEST (trial 1/3). Remove this script to revert. */
(function() {
  if (document.getElementById('msp-aurora-test-css')) return;
  var link = document.createElement('link');
  link.id = 'msp-aurora-test-css';
  link.rel = 'stylesheet';
  link.href = '/jellyfin-assets/aurora-client.css?v=' + Date.now();
  document.head.appendChild(link);
})();
