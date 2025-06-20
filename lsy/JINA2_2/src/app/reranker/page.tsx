"use client";

import { useEffect, useState } from "react";

export default function LearnMorePage() {
  const [html, setHtml] = useState("");

  useEffect(() => {
    fetch("/html/1.html")
      .then((res) => res.text())
      .then((text) => setHtml(text));
  }, []);

  if (!html) return <div className="p-4 text-center">加载中...</div>;

  return (
    <div
      className="w-full min-h-screen"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
