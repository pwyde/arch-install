-- No news window after LazyVim or Neovim updates.
return {
	"LazyVim/LazyVim",
	opts = {
		news = {
			lazyvim = false,
			neovim = false,
		},
	},
}
