// 中英双语：组件里直接写 tr('中文', 'English')，文案和用法放在一起，方便核对。
import { createContext, useContext } from 'react';

export const LangContext = createContext('zh');

export function useTr() {
  const lang = useContext(LangContext);
  const tr = (zh, en) => (lang === 'zh' ? zh : en);
  return { lang, tr };
}

export function initialLang() {
  try {
    const saved = localStorage.getItem('tapesurge:lang');
    if (saved === 'zh' || saved === 'en') return saved;
  } catch {
    /* 忽略 */
  }
  return navigator.language?.toLowerCase().startsWith('zh') ? 'zh' : 'en';
}

export function saveLang(lang) {
  try {
    localStorage.setItem('tapesurge:lang', lang);
  } catch {
    /* 忽略 */
  }
}
