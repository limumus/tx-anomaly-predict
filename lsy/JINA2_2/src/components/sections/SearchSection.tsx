"use client";

import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Search, Send } from "lucide-react";

export function SearchSection() {
  const [inputValue, setInputValue] = useState("");
  const [outputValue, setOutputValue] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!inputValue.trim()) return;

    setIsLoading(true);

    // Simulate API call with setTimeout
    setTimeout(() => {
      // Generate a simple response based on the input
      const response = `Response to: "${inputValue}"

This is a simulated response from the Jina AI search system. In a real implementation, this would connect to a backend API and return search results or AI-generated content based on your query.

Your query contained ${inputValue.split(' ').length} words and was processed successfully.`;

      setOutputValue(response);
      setIsLoading(false);
    }, 1500);
  };

  return (
    <section className="py-16 px-4 bg-black">
      <div className="container mx-auto max-w-4xl">
        <h2 className="text-3xl md:text-4xl font-bold text-white mb-8 text-center">
          Try Our Search API
        </h2>

        <div className="bg-zinc-900 border border-zinc-800 rounded-lg p-6 mb-8">
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="flex items-center gap-2 bg-zinc-800 rounded-md p-2 pl-4">
              <Search className="h-5 w-5 text-zinc-400" />
              <Input
                placeholder="Enter your search query or question..."
                className="border-0 bg-transparent focus-visible:ring-0 focus-visible:ring-offset-0 text-white placeholder:text-zinc-500"
                value={inputValue}
                onChange={(e) => setInputValue(e.target.value)}
              />
            </div>
            <Button
              type="submit"
              className="ml-auto bg-blue-600 hover:bg-blue-700 text-white"
              disabled={isLoading || !inputValue.trim()}
            >
              {isLoading ? "Processing..." : "Search"}
              <Send className="ml-2 h-4 w-4" />
            </Button>
          </form>
        </div>

        {outputValue && (
          <div className="bg-zinc-900 border border-zinc-800 rounded-lg p-6">
            <h3 className="text-xl font-semibold text-white mb-4">
              Results
            </h3>
            <div className="bg-zinc-950 p-4 rounded whitespace-pre-line text-zinc-300 font-mono text-sm">
              {outputValue}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
