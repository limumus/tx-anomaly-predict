"use client";

import Link from "next/link";
import Image from "next/image";
import { useState, useEffect } from "react";
import { useTheme } from "next-themes";
import { Menu, X, Globe, ChevronDown, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTrigger,
} from "@/components/ui/sheet";

const navLinks = [
  { name: "Home", href: "/" },
  { name: "Search", href: "#search" },
  { name: "Products", href: "#", dropdown: [
    { name: "DeepSearch", href: "/deepsearch" },
    { name: "Reader", href: "/reader" },
    { name: "Embeddings", href: "/embeddings" },
    { name: "Reranker", href: "/reranker" },
  ]},
  { name: "Support", href: "#", dropdown: [
    { name: "Documentation", href: "/docs" },
    { name: "FAQ", href: "/faq" },
  ]},
];

export function Navbar() {
  const [isOpen, setIsOpen] = useState(false);
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  // After mounting, we can safely show the UI
  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) {
    return null;
  }

  const isDark = theme === "dark";

  return (
    <nav className="fixed top-0 left-0 w-full z-50 bg-black/90 dark:bg-black/90 backdrop-blur-md border-b border-zinc-800">
      <div className="container flex h-16 items-center justify-between px-4 md:px-6">
        <div className="flex items-center gap-6">
          <Link href="/" className="flex items-center gap-2">
            <Image
              src="/images/jina-logo.svg"
              alt="Jina AI Logo"
              width={24}
              height={24}
              className="h-6 w-auto"
            />
          </Link>
          <div className="hidden md:flex gap-6">
            {navLinks.map((link) =>
              link.dropdown ? (
                <DropdownMenu key={link.name}>
                  <DropdownMenuTrigger asChild>
                    <Button
                      variant="link"
                      className="text-zinc-400 hover:text-white p-0 h-auto flex items-center gap-1"
                    >
                      {link.name} <ChevronDown className="h-4 w-4" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent
                    align="start"
                    className="bg-zinc-900 border-zinc-800"
                  >
                    {link.dropdown.map((item) => (
                      <DropdownMenuItem key={item.name} asChild>
                        <Link
                          href={item.href}
                          className="cursor-pointer hover:bg-zinc-800"
                        >
                          {item.name}
                        </Link>
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
              ) : (
                <Link
                  key={link.name}
                  href={link.href}
                  className="text-zinc-400 hover:text-white transition-colors"
                >
                  {link.name}
                </Link>
              )
            )}
          </div>
        </div>

        <div className="flex items-center gap-4">
          {/* Theme Toggle Button (Desktop) */}
          <Button
            variant="ghost"
            size="icon"
            className="text-zinc-400 hover:text-white"
            onClick={() => setTheme(isDark ? "light" : "dark")}
          >
            {isDark ? (
              <Sun className="h-5 w-5" />
            ) : (
              <Moon className="h-5 w-5" />
            )}
          </Button>

          {/* Mobile Menu */}
          <Sheet open={isOpen} onOpenChange={setIsOpen}>
            <SheetTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                className="md:hidden text-zinc-400"
              >
                {isOpen ? (
                  <X className="h-6 w-6" />
                ) : (
                  <Menu className="h-6 w-6" />
                )}
              </Button>
            </SheetTrigger>
            <SheetContent
              side="right"
              className="w-[85%] bg-zinc-900 border-zinc-800 p-0"
            >
              <SheetHeader className="p-6 border-b border-zinc-800">
                <Link href="/" className="flex items-center gap-2">
                  <Image
                    src="/images/jina-logo.svg"
                    alt="Jina AI Logo"
                    width={24}
                    height={24}
                    className="h-6 w-auto"
                  />
                </Link>
              </SheetHeader>
              <div className="py-6 px-6 flex flex-col gap-6">
                {navLinks.map((link) => (
                  <div key={link.name} className="flex flex-col gap-4">
                    {link.dropdown ? (
                      <>
                        <div className="text-zinc-400 font-medium">
                          {link.name}
                        </div>
                        <div className="flex flex-col gap-3 pl-4">
                          {link.dropdown.map((item) => (
                            <Link
                              key={item.name}
                              href={item.href}
                              className="text-zinc-300 hover:text-white"
                              onClick={() => setIsOpen(false)}
                            >
                              {item.name}
                            </Link>
                          ))}
                        </div>
                      </>
                    ) : (
                      <Link
                        href={link.href}
                        className="text-zinc-300 hover:text-white font-medium"
                        onClick={() => setIsOpen(false)}
                      >
                        {link.name}
                      </Link>
                    )}
                  </div>
                ))}

                {/* Theme Toggle Button (Mobile) */}
                <Button
                  variant="outline"
                  className="w-full justify-start text-zinc-400 hover:text-white"
                  onClick={() => setTheme(isDark ? "light" : "dark")}
                >
                </Button>
              </div>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </nav>
  );
}