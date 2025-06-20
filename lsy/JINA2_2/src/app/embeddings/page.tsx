// app/reader/page.tsx
"use client";

import { useEffect, useState } from "react";
import { useTheme } from "next-themes";

export default function ReaderPage() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [logContent, setLogContent] = useState("");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    setMounted(true);
    fetch("/logs/attack.log")
      .then((res) => res.text())
      .then((text) => setLogContent(text))
      .catch(() => setLogContent("❌ Failed to load log file."));
  }, []);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(logContent);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error("Copy failed:", err);
    }
  };

  if (!mounted) return null;

  const isDark = theme === "dark";

  return (
    <div className={`${isDark ? "bg-black text-white" : "bg-white text-black"} min-h-screen w-full`}>
      <main className="flex flex-col items-center w-full px-4 pt-20 pb-10">
        <h1 className="text-4xl font-bold text-center mb-8">Function Call Flow</h1>

        {/* 日志盒子（固定高度 + 内滚动） */}
        <div className="w-full max-w-5xl bg-zinc-900 text-green-300 rounded-md shadow-lg p-0 overflow-hidden">
          {/* 顶部工具栏 */}
          <div className="flex justify-between items-center px-4 py-2 border-b border-zinc-800 bg-zinc-800 text-sm text-zinc-300">
            <div>▶ 编译与执行日志</div>
            <button
              onClick={handleCopy}
              className="text-xs px-2 py-1 bg-zinc-700 text-zinc-200 hover:bg-zinc-600 rounded border border-zinc-500 transition"
            >
              {copied ? "✅ 已复制" : "复制日志"}
            </button>
          </div>

          {/* 日志内容（可滚动） */}
          <div className="h-[500px] overflow-y-auto p-6 font-mono text-sm whitespace-pre-wrap leading-relaxed">
            {logContent}
          </div>
        </div>

        {/* 页脚 */}
        <footer className="mt-16 text-center text-zinc-500 text-sm border-t border-zinc-800 pt-6 w-full max-w-5xl">
          © 2025 Blockchain Attack Detection Demo. All rights reserved.
        </footer>
      </main>
    </div>
  );
}

