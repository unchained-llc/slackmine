document.addEventListener('error', function (event) {
  var image = event.target;
  if (!(image instanceof HTMLImageElement)) return;
  if (!image.hasAttribute('data-slackmine-avatar-fallback')) return;
  var fallback = document.createElement('template');
  fallback.innerHTML = image.getAttribute('data-slackmine-avatar-fallback');
  image.replaceWith(fallback.content);
}, true);
