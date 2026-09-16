'use strict';

const languageSelect = document.getElementById('languageSelect');

function setArchitectureLanguage(value) {
  TabOutI18n.setLanguage(value);
  languageSelect.value = TabOutI18n.getLanguage();
  TabOutI18n.apply();
  document.title = `${TabOutI18n.t('Routing architecture')} · Tab Out`;
}

languageSelect.addEventListener('change', async event => {
  setArchitectureLanguage(event.target.value);
  try {
    await chrome.storage.local.set({ language: TabOutI18n.getLanguage() });
  } catch (error) {
    console.warn('[tab-out] Could not save language preference:', error);
  }
});

chrome.storage.local.get('language')
  .then(({ language }) => setArchitectureLanguage(language))
  .catch(error => {
    console.warn('[tab-out] Language preference unavailable:', error);
    setArchitectureLanguage('en');
  });
