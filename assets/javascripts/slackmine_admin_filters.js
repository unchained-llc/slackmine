(function () {
  document.addEventListener('change', function (event) {
    const control = event.target;
    const form = control.form;
    if (!form || !form.classList.contains('slackmine-admin-filter')) return;
    if (control.tagName !== 'SELECT' && control.type !== 'checkbox') return;
    form.requestSubmit();
  });
})();
