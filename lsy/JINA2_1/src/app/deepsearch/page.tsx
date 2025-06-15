"use client";

import { useTheme } from "next-themes";
import { useState, useEffect } from "react";
import Image from "next/image";
import { ChevronLeft, ChevronRight } from "lucide-react";

const imageList = [
  "/images/1/1.png",
  "/images/1/2.png",
  "/images/1/3.png",
];

export default function IndustryIntroPage() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [fade, setFade] = useState(true); // 控制淡入淡出动画

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) return null;

  const isDark = theme === "dark";

  const prevImage = () => {
    setFade(false);
    setTimeout(() => {
      setCurrentIndex((prev) => (prev - 1 + imageList.length) % imageList.length);
      setFade(true);
    }, 150);
  };

  const nextImage = () => {
    setFade(false);
    setTimeout(() => {
      setCurrentIndex((prev) => (prev + 1) % imageList.length);
      setFade(true);
    }, 150);
  };

  return (
    <main
      className={`min-h-screen py-24 px-6 md:px-16 transition-colors duration-300 ${
        isDark ? "bg-black text-white" : "bg-zinc-50 text-zinc-900"
      }`}
    >
      <div className="max-w-7xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-12 items-center">
        {/* 左侧文字介绍 */}
        <section>
          <h1 className="text-4xl font-bold mb-6">模型创新点概览</h1>
          <p className="text-lg leading-relaxed mb-6">
            针对现有智能合约漏洞检测技术依赖静态分析、难以有效建模动态交易场景攻击模式的局限性，本项目提出一种基于多模态检索增强生成（RAG）框架的智能交易语义分析系统。
          </p>
          <p className="text-lg leading-relaxed mb-6">
            该系统通过动态模拟，在仿真环境中实现合约逻辑的状态追踪与攻击检测，建立静态代码语义与动态行为的多维映射，并引入调用路径的跨模态对齐以实现未标注交易的语义融合检测。
          </p>
          <p className="text-lg leading-relaxed">
            该方案有效阻断攻击链扩散，降低了传统方法因依赖标注数据导致的漏报率，显著提升了系统对复杂攻击场景的认知和理解能力。
          </p>
        </section>

        {/* 右侧单张图片 */}
        <section className="relative w-full h-[420px] flex items-center justify-center overflow-visible rounded-xl shadow-lg">
          {/* 左按钮 */}
          <button
            onClick={prevImage}
            aria-label="上一张"
            className="absolute left-4 z-20 p-2 bg-white/20 backdrop-blur rounded-full hover:bg-white/30 transition"
          >
            <ChevronLeft className="w-6 h-6" />
          </button>

          {/* 当前图片容器，宽度改成适合单张图 */}
          <div className="relative w-[400px] h-[400px] flex items-center justify-center">
            <Image
              key={currentIndex}
              src={imageList[currentIndex]}
              alt={`行业示意图 ${currentIndex + 1}`}
              width={400}
              height={400}
              className={`rounded-xl shadow-xl cursor-pointer transition-opacity duration-500 ease-in-out ${
                fade ? "opacity-100" : "opacity-0"
              }`}
              style={{ objectFit: "contain" }}
              draggable={false}
            />
          </div>

          {/* 右按钮 */}
          <button
            onClick={nextImage}
            aria-label="下一张"
            className="absolute right-4 z-20 p-2 bg-white/20 backdrop-blur rounded-full hover:bg-white/30 transition"
          >
            <ChevronRight className="w-6 h-6" />
          </button>

          {/* 底部指示点 */}
          <div className="absolute bottom-8 flex gap-2 justify-center w-full">
            {imageList.map((_, index) => (
              <span
                key={index}
                className={`w-2.5 h-2.5 rounded-full transition-all ${
                  index === currentIndex
                    ? "bg-white/80 scale-125"
                    : "bg-white/40"
                }`}
              ></span>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}
