"use client";

import Link from "next/link";
import { Button } from "@/components/ui/button";
import { ArrowRight, Rss, Twitter } from "lucide-react";

// Sample news items
const newsItems = [
  {
    category: "Tech blog",
    title: "A Practical Guide to Implementing DeepSearch/DeepResearch",
    date: "February 25, 2025",
    readTime: "19 minutes read",
    color: "bg-amber-900/30",
    borderColor: "border-amber-800"
  },
  {
    category: "Tech blog",
    title: "Using DeepSeek R1 Reasoning Model in DeepSearch",
    date: "April 01, 2025",
    readTime: "17 minutes read",
    color: "bg-amber-900/30",
    borderColor: "border-amber-800"
  },
  {
    category: "Tech blog",
    title: "DeepSearch on Private Visual Documents: An Enterprise Case Study",
    date: "March 31,, 2025",
    readTime: "7 minutes read",
    color: "bg-amber-900/30",
    borderColor: "border-amber-800"
  }
];

export function NewsroomSection() {
  return (
    <section className="py-24 px-4 bg-black">
      <div className="container mx-auto">
        <h2 className="text-3xl md:text-4xl font-bold text-white mb-16 text-center">
          Newsroom
        </h2>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {newsItems.map((item, index) => (
            <Link
              href="/news"
              key={index}
              className={`p-6 flex flex-col justify-between rounded-lg border ${item.borderColor} ${item.color} hover:bg-opacity-50 transition-all min-h-[280px]`}
            >
              <div>
                <div className="text-sm font-medium text-zinc-400 mb-1">
                  {item.category}
                </div>
                <h3 className="text-xl font-semibold text-white mb-4">
                  {item.title}
                </h3>
              </div>
              <div className="text-sm text-zinc-400">
                {item.date} · {item.readTime}
              </div>
            </Link>
          ))}
        </div>

        <div className="flex flex-wrap justify-center gap-4 mt-10">
          <Button
            asChild
            variant="outline"
            className="bg-transparent hover:bg-zinc-900 text-zinc-400 hover:text-white border-zinc-800"
          >
            <Link href="/news" className="group">
              Read more <ArrowRight className="ml-2 h-4 w-4 group-hover:translate-x-1 transition-transform" />
            </Link>
          </Button>

          <Button
            asChild
            variant="outline"
            className="bg-transparent hover:bg-zinc-900 text-zinc-400 hover:text-white border-zinc-800"
          >
            <Link href="/feed.rss">
              <Rss className="mr-2 h-4 w-4" /> RSS
            </Link>
          </Button>

          <Button
            asChild
            variant="outline"
            className="bg-transparent hover:bg-zinc-900 text-zinc-400 hover:text-white border-zinc-800"
          >
            <Link href="https://twitter.com/jinaAI_" target="_blank" rel="noopener noreferrer">
              <Twitter className="mr-2 h-4 w-4" />
            </Link>
          </Button>
        </div>
      </div>
    </section>
  );
}
