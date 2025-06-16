"use client";

import { useTheme } from "next-themes";
import { useState, useEffect } from "react";
import Image from "next/image";
import { ChevronLeft, ChevronRight } from "lucide-react";

const imageList = [
  "/images/2/1.png",
  "/images/2/2.png",
  "/images/2/3.png",
  "/images/2/4.png",
];

export default function ReaderPage() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) return null;

  const isDark = theme === "dark";

  const prevImage = () => {
    setCurrentIndex((prev) => (prev - 1 + imageList.length) % imageList.length);
  };

  const nextImage = () => {
    setCurrentIndex((prev) => (prev + 1) % imageList.length);
  };

  return (
    <main
      className={`min-h-screen py-24 px-4 flex flex-col items-center justify-center ${
        isDark ? "bg-black text-white" : "bg-zinc-50 text-zinc-900"
      }`}
    >
      <h1 className="text-4xl font-bold mb-6 text-center">数据集一览</h1>

      <div className="relative w-full max-w-6xl flex items-center justify-center overflow-hidden">
        {/* Left button */}
        <button
          onClick={prevImage}
          className="absolute left-4 z-10 p-2 bg-white/10 backdrop-blur rounded-full hover:bg-white/20 transition"
        >
          <ChevronLeft className="w-6 h-6" />
        </button>

        {/* Image slider */}
        <div className="flex items-center justify-center w-full relative h-[500px]">
          {imageList.map((src, index) => {
            const isActive = index === currentIndex;
            const isPrev = index === (currentIndex - 1 + imageList.length) % imageList.length;
            const isNext = index === (currentIndex + 1) % imageList.length;

            let className = "absolute transition-all duration-500 ease-in-out";

            if (isActive) {
              className += " scale-100 z-20 opacity-100";
            } else if (isPrev) {
              className += " -translate-x-[300px] scale-75 opacity-50 z-10";
            } else if (isNext) {
              className += " translate-x-[300px] scale-75 opacity-50 z-10";
            } else {
              className += " opacity-0 z-0";
            }

            return (
              <Image
                key={index}
                src={src}
                alt={`Image ${index}`}
                width={600}
                height={400}
                className={`${className} rounded-xl shadow-lg`}
              />
            );
          })}
        </div>

        {/* Right button */}
        <button
          onClick={nextImage}
          className="absolute right-4 z-10 p-2 bg-white/10 backdrop-blur rounded-full hover:bg-white/20 transition"
        >
          <ChevronRight className="w-6 h-6" />
        </button>
      </div>
    </main>
  );
}
