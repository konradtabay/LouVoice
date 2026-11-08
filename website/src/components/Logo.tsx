import LogoMark from '@/components/LogoMark'
import { Link } from '@/router'

export default function Logo() {
  return (
    <Link to="/" className="flex items-center gap-3" aria-label="LouVoice home">
      <LogoMark className="h-9 w-auto text-[#3d1689]" />
      <span className="font-heading text-[26px] font-bold tracking-tight [font-variation-settings:'wdth'_80]">LouVoice</span>
    </Link>
  )
}
