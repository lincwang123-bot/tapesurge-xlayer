// 读链上数据的小工具：首次加载 + 定时刷新 + 手动刷新；切换依赖时丢弃旧请求的结果。
import { useCallback, useEffect, useRef, useState } from 'react';

// refresh：交易完成后的刷新信号（app.version）。它变了只静默重读，保留现有数据，
// 不会让页面闪回"加载中"、卸掉下面的组件（否则输入框和刚签好的卖单链接会丢）。
export function useAsync(fn, deps, { interval = 0, refresh } = {}) {
  const [state, setState] = useState({ data: undefined, error: null, loading: true });
  const seq = useRef(0);
  const fnRef = useRef(fn);
  fnRef.current = fn;

  const run = useCallback(async (quiet) => {
    const id = ++seq.current;
    if (!quiet) setState((s) => ({ ...s, loading: true }));
    try {
      const data = await fnRef.current();
      if (id === seq.current) setState({ data, error: null, loading: false });
    } catch (error) {
      if (id === seq.current) setState((s) => ({ data: s.data, error, loading: false }));
    }
  }, []);

  useEffect(() => {
    setState({ data: undefined, error: null, loading: true });
    run(false);
    if (!interval) return undefined;
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') run(true);
    }, interval);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    run(true);
  }, [refresh, run]);

  return { ...state, reload: () => run(true) };
}

/** 每秒更新一次的当前时间（秒），用于倒计时 */
export function useNow() {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}
