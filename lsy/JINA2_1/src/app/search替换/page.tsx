"use client";

import { useState, useEffect } from 'react';
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Search, ArrowLeft } from "lucide-react";
import { useTheme } from "next-themes";
import Image from 'next/image';
import axios from "axios";

const SearchIconSVG = '/images/huggingface-logo.svg';

export default function SearchPage() {
  const [inputValue, setInputValue] = useState("");
  const [outputValue, setOutputValue] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [history, setHistory] = useState<string[]>([]);
  const [showResult, setShowResult] = useState(false);
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    const fetchHistory = async () => {
      try {
        const response = await axios.get("http://127.0.0.1:5000/history");
        setHistory(response.data.history || []);
      } catch (error) {
        console.error("Error fetching history:", error);
      }
    };
    fetchHistory();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!inputValue.trim()) return;

    setIsLoading(true);
    try {
      const response = await axios.post("http://127.0.0.1:5000/analyze", { query: inputValue });
      setOutputValue(response.data.result || "No results found.");
      setShowResult(true);

      await axios.post("http://127.0.0.1:5000/save_history", { query: inputValue });
      setHistory(prev => [...prev, inputValue]);
    } catch (error) {
      console.error("查询失败:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleBack = () => {
    setShowResult(false);
  };

  if (!mounted) return null;

  const isDark = theme === "dark";

  return (
    <section className={`min-h-screen flex items-center justify-center px-4 ${isDark ? "bg-black" : "bg-zinc-50"}`}>
      <div className="container mx-auto max-w-4xl">
        <div className="flex justify-center mb-8">
          <Image
            src={SearchIconSVG}
            alt="Search Icon"
            width={50}
            height={50}
            className={`transition-opacity ${outputValue ? "opacity-50" : "opacity-100"}`}
          />
        </div>

        <div className={`relative transition-all duration-300 ${outputValue ? "mt-8" : ""}`}>
          <h2 className={`text-3xl md:text-4xl font-bold ${isDark ? "text-white" : "text-zinc-900"} mb-8 text-center`}>
            Text Query Processor
          </h2>

          {!showResult && (
            <div className={`rounded-lg p-6 ${isDark ? "bg-zinc-900 border-zinc-800" : "bg-white border-zinc-200"} border transition-shadow shadow-lg`}>
              <form onSubmit={handleSubmit} className="flex flex-col gap-4">
                <div className={`relative flex items-center gap-2 rounded-md p-2 pl-4 ${isDark ? "bg-zinc-800" : "bg-zinc-100"}`}>
                  <Search className={`h-5 w-5 ${isDark ? "text-zinc-400" : "text-zinc-500"}`} />
                  <Input
                    placeholder="Enter your query..."
                    className={`border-0 bg-transparent focus-visible:ring-0 focus-visible:ring-offset-0 ${isDark ? "text-white placeholder:text-zinc-500" : "text-zinc-900 placeholder:text-zinc-400"}`}
                    value={inputValue}
                    onChange={(e) => setInputValue(e.target.value)}
                    autoFocus
                  />
                </div>

                <Button
                  type="submit"
                  className={`ml-auto ${isDark ? "bg-blue-600 hover:bg-blue-700" : "bg-blue-500 hover:bg-blue-600"} text-white`}
                  disabled={isLoading || !inputValue.trim()}
                >
                  {isLoading ? "Processing..." : "Search"}
                </Button>
              </form>
            </div>
          )}

          {showResult && (
            <div className={`mt-4 rounded-lg p-6 ${isDark ? "bg-zinc-900 border-zinc-800" : "bg-white border-zinc-200"} border shadow-lg transition-all duration-300 animate-fade-in`}>
              <h3 className={`text-xl font-semibold ${isDark ? "text-white" : "text-zinc-900"} mb-4`}>
                Query Results
              </h3>

              <textarea
                value={outputValue}
                onChange={(e) => setOutputValue(e.target.value)}
                className={`w-full min-h-[200px] p-4 rounded font-mono text-sm resize-vertical outline-none focus:ring-2 ${isDark ? "bg-zinc-950 text-zinc-300 ring-zinc-700" : "bg-zinc-100 text-zinc-800 ring-blue-300"}`}
              />

              <Button
                variant="outline"
                className={`mt-6 ml-auto ${isDark ? "text-white border-zinc-700 hover:bg-zinc-800" : "text-zinc-900 border-zinc-300 hover:bg-zinc-100"}`}
                onClick={handleBack}
              >
                <ArrowLeft className="mr-2 h-4 w-4" />
                Back
              </Button>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
