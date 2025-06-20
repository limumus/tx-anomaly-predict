"use client";

import { useTheme } from "next-themes";
import { useState, useEffect } from "react";
import Image from "next/image";
import { ChevronLeft, ChevronRight } from "lucide-react";

const imageSections = [
  {
    title: "模型创新点概览",
    description: [
      "针对现有智能合约漏洞检测技术依赖静态分析、难以有效建模动态交易场景攻击模式的局限性，本项目提出一种基于多模态检索增强生成（RAG）框架的智能交易语义分析系统。",
      "该系统通过动态模拟，在仿真环境中实现合约逻辑的状态追踪与攻击检测，建立静态代码语义与动态行为的多维映射，并引入调用路径的跨模态对齐以实现未标注交易的语义融合检测。",
      "该方案有效阻断攻击链扩散，降低了传统方法因依赖标注数据导致的漏报率，显著提升了系统对复杂攻击场景的认知和理解能力。"
    ],
    images: ["/images/1/1.png"]
  },
  {
    title: "数据集一览",
    description: [
      "我们采用的数据集样本种类丰富，涵盖了多种典型的智能合约漏洞类型，如重入攻击、授权缺陷、闪电贷滥用等，具有较强的代表性和多样性，能够全面支持对恶意行为的建模与识别。",
      "数据总量达到 256,959 份，其中包括 38,483 份恶意合约 和 221,752 份非恶意合约，为模型训练和评估提供了充足的数据基础，有助于提高识别的准确性与鲁棒性。",
      "经过清洗与验证，数据的有效率高达 86.7%，确保了高质量的输入源，减少了噪声对分析结果的干扰，提升了实验的可靠性和可重复性。",
      "此外，样本的时间范围覆盖 2018 至 2023 年，具备良好的时间跨度特性，有助于模型学习不同时期的攻击行为特征，更贴近实际应用场景的演化趋势。"
    ],
    images: ["/images/2/1.png", "/images/2/2.png", "/images/2/3.png", "/images/2/4.png"]
  },
  {
    title: "模型运行结果一览",
    description: [
      "我们的模型在运行过程中展现出良好的性能表现。整体来看，针对不同类型攻击的识别准确度虽存在一定差异，但普遍维持在 80% 以上，在多数典型攻击场景下具备稳定的检测能力。综合来看，模型的平均判断精度达到了 87.9%，兼顾准确率与分析效率，能够为实际合约安全检测提供可靠支持。",
      "在效率方面，模型在大部分情况下能够快速完成合约分析与判断，具备良好的响应速度，仅在极个别复杂调用链或跨合约交互场景中分析时间相对较长，但仍在可接受范围内。"
    ],
    images: ["/images/3/1.png", "/images/3/2.png", "/images/3/3.png"]
  }
];

export default function CombinedCarouselPage() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [currentIndexes, setCurrentIndexes] = useState(imageSections.map(() => 0));
  const [fadeIns, setFadeIns] = useState(imageSections.map(() => true));

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) return null;

  const isDark = theme === "dark";

  const updateIndex = (sectionIdx: number, newIndex: number) => {
    setFadeIns((prev) => {
      const newFade = [...prev];
      newFade[sectionIdx] = false;
      return newFade;
    });
    setTimeout(() => {
      setCurrentIndexes((prev) => {
        const updated = [...prev];
        updated[sectionIdx] = newIndex;
        return updated;
      });
      setFadeIns((prev) => {
        const newFade = [...prev];
        newFade[sectionIdx] = true;
        return newFade;
      });
    }, 150);
  };

  return (
    <main className={`min-h-screen py-24 px-6 md:px-16 transition-colors duration-300 ${isDark ? "bg-black text-white" : "bg-zinc-50 text-zinc-900"}`}>
      <div className="max-w-7xl mx-auto flex flex-col gap-24">
        {imageSections.map((section, idx) => (
          <div key={idx} className="grid grid-cols-1 md:grid-cols-2 gap-12 items-center">
            <section>
              <h2 className="text-4xl font-bold mb-6 text-center md:text-left">{section.title}</h2>
              {section.description.map((line, i) => (
                <p key={i} className="text-lg leading-relaxed mb-6">{line}</p>
              ))}
            </section>

            {/* 第一部分不显示轮播，仅展示一张图 */}
            {idx === 0 ? (
              <section className="relative w-full h-[420px] flex items-center justify-center overflow-visible rounded-xl shadow-lg">
                <Image
                  src={section.images[0]}
                  alt="示意图"
                  width={400}
                  height={400}
                  className="rounded-xl shadow-xl object-contain"
                  draggable={false}
                />
              </section>
            ) : (
              <section className="relative w-full h-[420px] flex items-center justify-center overflow-visible rounded-xl shadow-lg">
                <button
                  onClick={() => updateIndex(idx, (currentIndexes[idx] - 1 + section.images.length) % section.images.length)}
                  aria-label="上一张"
                  className="absolute left-4 z-20 p-2 bg-white/20 backdrop-blur rounded-full hover:bg-white/30 transition"
                >
                  <ChevronLeft className="w-6 h-6" />
                </button>

                <div className="relative w-[400px] h-[400px] flex items-center justify-center">
                  <Image
                    key={currentIndexes[idx]}
                    src={section.images[currentIndexes[idx]]}
                    alt={`示意图 ${currentIndexes[idx] + 1}`}
                    width={400}
                    height={400}
                    className={`rounded-xl shadow-xl transition-opacity duration-500 ease-in-out ${fadeIns[idx] ? "opacity-100" : "opacity-0"}`}
                    style={{ objectFit: "contain" }}
                    draggable={false}
                  />
                </div>

                <button
                  onClick={() => updateIndex(idx, (currentIndexes[idx] + 1) % section.images.length)}
                  aria-label="下一张"
                  className="absolute right-4 z-20 p-2 bg-white/20 backdrop-blur rounded-full hover:bg-white/30 transition"
                >
                  <ChevronRight className="w-6 h-6" />
                </button>

                <div className="absolute bottom-8 flex gap-2 justify-center w-full">
                  {section.images.map((_, imageIdx) => (
                    <span
                      key={imageIdx}
                      className={`w-2.5 h-2.5 rounded-full transition-all ${
                        imageIdx === currentIndexes[idx] ? "bg-white/80 scale-125" : "bg-white/40"
                      }`}
                    ></span>
                  ))}
                </div>
              </section>
            )}
          </div>
        ))}
      </div>
    </main>
  );
}
