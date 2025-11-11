# my_configs

```
mkdir -p ~/.vim/bundle
git clone https://github.com/Shougo/neobundle.vim ~/.vim/bundle/neobundle.vim

git clone git@github.com:ikagawa/my_configs.git

rm .bashrc
rm .vimrc
ln -s my_configs/bin .
ln -s my_configs/dot_bashrc .bashrc
ln -s my_configs/dot_mostrc .mostrc
ln -s my_configs/dot_tigrc .tigrc
ln -s my_configs/dot_tmux.conf .tmux.conf
ln -s my_configs/dot_vimrc .vimrc
```
