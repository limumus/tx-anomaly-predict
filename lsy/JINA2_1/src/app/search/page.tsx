"use client";

import { useState, useEffect } from 'react';
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Search, Send, FolderInput } from "lucide-react";
import { useTheme } from "next-themes";
import Image from 'next/image';

const SearchIconSVG = '/images/huggingface-logo.svg';

export default function SearchPage() {
  const [inputValue, setInputValue] = useState("");
  const [outputValue, setOutputValue] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [history, setHistory] = useState<string[]>([]);
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [filePath, setFilePath] = useState("");

  useEffect(() => {
    setMounted(true);

    // 获取历史记录
    const fetchHistory = async () => {
      try {
        const response = await window.electronAPI.getHistory();
        setHistory(response);
      } catch (error) {
        console.error('Error fetching history:', error);
      }
    };

    fetchHistory();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!inputValue.trim() && !filePath) return;

    setIsLoading(true);

    try {
      // 调用本地Python处理
      const response = await window.electronAPI.processFile({
        query: inputValue,
        filePath: filePath
      });
      
      setOutputValue(response);

      // 保存历史记录
      if (inputValue.trim()) {
        await window.electronAPI.saveToHistory(inputValue);
        setHistory(prevHistory => [...prevHistory, inputValue]); // 更新历史记录
      }
    } catch (error) {
      //setOutputValue(`Error processing file: ${error.message}`);
    } finally {
      setIsLoading(false);
    }
  };

  const handleFileSelect = async () => {
    try {
      // 通过Electron API打开文件选择对话框
      const path = await window.electronAPI.openFileDialog();
      if (path) {
        setFilePath(path);
      }
    } catch (error) {
      console.error('Error selecting file:', error);
    }
  };

  // 根据输入值过滤历史记录
  const filteredHistory = history.filter(item =>
    item.toLowerCase().includes(inputValue.toLowerCase())
  );

  // 选择历史记录时填充输入框
  const handleHistorySelect = (historyItem: string) => {
    setInputValue(historyItem);
  };

  if (!mounted) {
    return null;
  }

  const isDark = theme === "dark";

  return (
    <section className={`min-h-screen flex items-center justify-center px-4 ${isDark ? 'bg-black' : 'bg-zinc-50'}`}>
      <div className="container mx-auto max-w-4xl">
        {/* 搜索图标 */}
        <div className="flex justify-center mb-8">
          <Image
            src={SearchIconSVG}
            alt="Search Icon"
            width={50}
            height={50}
            className={`transition-opacity ${outputValue ? 'opacity-50' : 'opacity-100'}`}
          />
        </div>

        <div className={`relative transition-all duration-300 ${outputValue ? 'mt-8' : ''}`}>
          <h2 className={`text-3xl md:text-4xl font-bold ${isDark ? 'text-white' : 'text-zinc-900'} mb-8 text-center`}>
            Document Processor
          </h2>

          <div className={`rounded-lg p-6 ${isDark ? 'bg-zinc-900 border-zinc-800' : 'bg-white border-zinc-200'} border transition-shadow ${outputValue ? 'shadow-lg' : ''}`}>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              {/* 文件选择部分 */}
              <div className="flex flex-col gap-2">
                <label className={`text-sm ${isDark ? 'text-zinc-400' : 'text-zinc-600'}`}>
                  Select a document to process:
                </label>
                <div className="flex gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    onClick={handleFileSelect}
                    className={`flex items-center gap-2 ${isDark ? 'bg-zinc-800 hover:bg-zinc-700' : 'bg-zinc-100 hover:bg-zinc-200'}`}
                  >
                    <FolderInput className="h-4 w-4" />
                    Choose File
                  </Button>
                  {filePath && (
                    <div className={`flex-1 truncate p-2 rounded ${isDark ? 'bg-zinc-800 text-zinc-300' : 'bg-zinc-100 text-zinc-700'}`}>
                      {filePath.split(/[\\/]/).pop()}
                    </div>
                  )}
                </div>
              </div>

              {/* 查询输入部分 */}
              <div className={`relative flex items-center gap-2 rounded-md p-2 pl-4 ${isDark ? 'bg-zinc-800' : 'bg-zinc-100'}`}>
                <Search className={`h-5 w-5 ${isDark ? 'text-zinc-400' : 'text-zinc-500'}`} />
                <Input
                  placeholder="Enter your query (optional)..."
                  className={`border-0 bg-transparent focus-visible:ring-0 focus-visible:ring-offset-0 ${isDark ? 'text-white placeholder:text-zinc-500' : 'text-zinc-900 placeholder:text-zinc-400'}`}
                  value={inputValue}
                  onChange={(e) => setInputValue(e.target.value)}
                />
                {/* 过滤后的历史记录下拉框 */}
                {inputValue && filteredHistory.length > 0 && (
                  <div className="absolute left-0 right-0 mt-2 bg-white border rounded-md shadow-lg z-10 max-h-40 overflow-y-auto">
                    {filteredHistory.map((item, index) => (
                      <div
                        key={index}
                        className={`p-2 cursor-pointer hover:bg-blue-100 ${isDark ? 'text-white' : 'text-zinc-900'}`}
                        onClick={() => handleHistorySelect(item)}
                      >
                        {item}
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <Button
                type="submit"
                className={`ml-auto ${isDark ? 'bg-blue-600 hover:bg-blue-700' : 'bg-blue-500 hover:bg-blue-600'} text-white`}
                disabled={isLoading || (!inputValue.trim() && !filePath)}
              >
                {isLoading ? "Processing..." : "Process Document"}
                <Send className="ml-2 h-4 w-4" />
              </Button>
            </form>
          </div>

          {outputValue && (
            <div className={`mt-4 rounded-lg p-6 ${isDark ? 'bg-zinc-900 border-zinc-800' : 'bg-white border-zinc-200'} border shadow-lg transition-all duration-300 animate-fade-in`}>
              <h3 className={`text-xl font-semibold ${isDark ? 'text-white' : 'text-zinc-900'} mb-4`}>
                Processing Results
              </h3>
              <div className={`p-4 rounded whitespace-pre-line font-mono text-sm ${isDark ? 'bg-zinc-950 text-zinc-300' : 'bg-zinc-100 text-zinc-800'}`}>
                {outputValue}
              </div>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
